import UIKit
import CoreLocation
import UserNotifications

// ===== 注册后引导（2026-11-18 Li 定，按注册后引导预览做 App 实现）=====
// 流程：P0–P3 引导 → 位置步 → 通知步 → 结束页。只给新注册用户、只弹一次。
// 与首启 v3 引导的区别：v3 是装完未登录时的 4 页介绍（首启触发已退役，
// 仅设置页重播保留）；本流程在注册成功后出现，含权限步与 ID 卡接线。
// 文案一字未动（P2 标题与导语在预览里就是同一句，原文保留）。
// 翻页只左右滑入（0.34s），不要上下渐显；横向留白统一 24。
// 固定浅色按预览 token（页面 #f4f4f2、墨 #111、弱 #8a8a86）；
// 衬线只走展示性大标题（withDesign(.serif)，New York＋宋体），其余系统字体。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyOnboardingPalette {
    static let pageBackground = UIColor(red: 244.0 / 255.0, green: 244.0 / 255.0, blue: 242.0 / 255.0, alpha: 1)
    static let cardBackground = UIColor.white
    static let ink = UIColor(red: 17.0 / 255.0, green: 17.0 / 255.0, blue: 17.0 / 255.0, alpha: 1)
    static let ink2 = UIColor(red: 58.0 / 255.0, green: 58.0 / 255.0, blue: 58.0 / 255.0, alpha: 1)
    static let muted = UIColor(red: 138.0 / 255.0, green: 138.0 / 255.0, blue: 134.0 / 255.0, alpha: 1)
    static let faint = UIColor(red: 199.0 / 255.0, green: 199.0 / 255.0, blue: 204.0 / 255.0, alpha: 1)
    static let line = UIColor(red: 230.0 / 255.0, green: 230.0 / 255.0, blue: 230.0 / 255.0, alpha: 1)
    static let line2 = UIColor(red: 239.0 / 255.0, green: 239.0 / 255.0, blue: 239.0 / 255.0, alpha: 1)
    static let track = UIColor(red: 217.0 / 255.0, green: 217.0 / 255.0, blue: 217.0 / 255.0, alpha: 1)
    static let blueSoft = UIColor(red: 238.0 / 255.0, green: 245.0 / 255.0, blue: 255.0 / 255.0, alpha: 1)
    static let loveSoft = UIColor(red: 253.0 / 255.0, green: 238.0 / 255.0, blue: 242.0 / 255.0, alpha: 1)
    static let cheerSoft = UIColor(red: 255.0 / 255.0, green: 243.0 / 255.0, blue: 223.0 / 255.0, alpha: 1)
    static let chipSelectedBackground = UIColor(red: 255.0 / 255.0, green: 250.0 / 255.0, blue: 242.0 / 255.0, alpha: 1)
    static let orange = BearyColors.orange
    static let linkBlue = BearyColors.blue
    static let switchGreen = UIColor(red: 52.0 / 255.0, green: 199.0 / 255.0, blue: 89.0 / 255.0, alpha: 1)
    static let tagBackground = UIColor(red: 242.0 / 255.0, green: 242.0 / 255.0, blue: 242.0 / 255.0, alpha: 1)
}

extension UIFont {
    static func onboardingSerif(ofSize size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        // UIKit 没有 UIFont.withDesign（那是 SwiftUI Font 的 API）：走
        // UIFontDescriptor.withDesign(.serif) 再拼回 UIFont。
        if let descriptor = base.fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return base
    }
}

final class BearyPostRegistrationOnboardingViewController: UIViewController, UIGestureRecognizerDelegate {

    // MARK: - Public API

    /// 流程走完后由容器接：写 seen、关本页、400ms 后弹 ID 卡表单。
    var onFinished: (() -> Void)?

    /// 位置步拿到的定位城市（三级全中才有，供 ID 卡表单预填；没给权限为空）。
    private(set) var locatedCity: (country: String, region: String, city: String)?
    private(set) var locationGranted = false

    // MARK: - Steps

    private enum Step: Int {
        case p0 = 0, p1, p2, p3, location, notification, done
    }

    private enum Direction {
        case forward, back
    }

    private enum Visibility {
        case `public`, friends, selfOnly
    }

    /// 反应 chip 与表单共用（文件级 ReactionChipView 亦用），故用 fileprivate。
    fileprivate enum Reaction: String {
        case hug, love, cheer

        var emoteKey: String { rawValue }
        var displayName: String {
            switch self {
            case .hug: return "抱一抱"
            case .love: return "陪陪你"
            case .cheer: return "为你开心"
            }
        }

        var circleBackground: UIColor {
            switch self {
            case .hug: return BearyOnboardingPalette.blueSoft
            case .love: return BearyOnboardingPalette.loveSoft
            case .cheer: return BearyOnboardingPalette.cheerSoft
            }
        }
    }

    private var step: Step = .p0
    private var isTransitioning = false

    // MARK: - State（视图每次重建都从这里恢复）

    private var visibility: Visibility = .selfOnly
    private var reaction: Reaction?
    private var locationChoiceMade = false
    private var locationCityText = "未获取定位"
    private var isRequestingLocation = false
    /// 定位请求代次：旧请求晚到时丢弃，不覆盖新请求的状态（跳步后落地的旧结果同此）。
    private var locationGeneration = 0
    private var reminderOn = BearyLocalNotifications.shared.isEnabled(.dailyReminder)
    private var notificationChoiceMade = false
    private var isRequestingNotification = false

    // P3 打字机：「今天」常驻，后文逐字慢打，不循环；重进重打。
    private static let typewriterSuffix = "，楼下的猫又睡在了台阶上。"
    private var typewriterTimer: Timer?
    private var typedCount = 0
    private weak var typedLabel: UILabel?

    // P2 反应 chip 与提示行（重建后重新收集引用）。
    private var reactionChips: [ReactionChipView] = []
    private weak var reactionNoteLabel: UILabel?

    // MARK: - Chrome views

    private let topBarView = UIView()
    private let backButton = UIButton(type: .system)
    private let pageLabel = UILabel()
    private let skipButton = UIButton(type: .system)
    private let segmentsView = UIView()
    private var segmentBars: [UIView] = []
    private let containerView = UIView()
    private var currentStepView: UIView?
    private let footerView = UIView()
    private var footerHeightConstraint: NSLayoutConstraint?
    private let primaryButton = UIButton(type: .custom)
    private let secondaryButton = UIButton(type: .system)

    // MARK: - Interactive pan（1:1 跟手；过 1/3 宽或甩速 >600pt/s 即翻页，否则弹回）

    private lazy var panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private var panActive = false
    private var panTargetStep: Step?
    private var panTargetDirection: Direction?
    private var panTargetView: UIView?
    /// 拖动待定：.began 时速度常为 ~0，方向等 changed 里按累计位移定（M5）。
    private var panPending = false

    deinit {
        typewriterTimer?.invalidate()
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyOnboardingPalette.pageBackground
        buildChrome()
        containerView.addGestureRecognizer(panGesture)
        panGesture.delegate = self
        let initialView = stepView(for: .p0)
        installStepView(initialView, initialTransform: .identity)
        currentStepView = initialView
        updateChrome()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopTypewriter()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // P3 打字机：页面被盖住又回来时从断点续打（不重置已打的字）。
        if step == .p3, typewriterTimer == nil, typedCount < Self.typewriterSuffix.count {
            if UIAccessibility.isReduceMotionEnabled {
                typedLabel?.text = Self.typewriterSuffix
                typedCount = Self.typewriterSuffix.count
            } else {
                scheduleNextTypewriterChar(after: 0.15)
            }
        }
    }

    // MARK: - Chrome

    private func buildChrome() {
        // 顶栏：返回左、页码中、跳过右。
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBarView)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = BearyOnboardingPalette.ink
        backButton.contentHorizontalAlignment = .left
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.accessibilityLabel = "返回"
        topBarView.addSubview(backButton)
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        pageLabel.textAlignment = .center
        pageLabel.textColor = BearyOnboardingPalette.faint
        pageLabel.font = UIFont.systemFont(ofSize: 13)
        topBarView.addSubview(pageLabel)
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.setTitle("跳过", for: .normal)
        skipButton.setTitleColor(BearyOnboardingPalette.ink, for: .normal)
        skipButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        skipButton.contentHorizontalAlignment = .right
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        topBarView.addSubview(skipButton)
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 12),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            pageLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            pageLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            skipButton.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor, constant: -24),
            skipButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            skipButton.widthAnchor.constraint(equalToConstant: 60),
            skipButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        // 6 段进度条。
        segmentsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(segmentsView)
        let segmentsStack = UIStackView()
        segmentsStack.translatesAutoresizingMaskIntoConstraints = false
        segmentsStack.axis = .horizontal
        segmentsStack.spacing = 6
        segmentsView.addSubview(segmentsStack)
        for _ in 0..<6 {
            let bar = UIView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.backgroundColor = BearyOnboardingPalette.track
            bar.layer.cornerRadius = 2
            bar.widthAnchor.constraint(equalToConstant: 24).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 4).isActive = true
            segmentsStack.addArrangedSubview(bar)
            segmentBars.append(bar)
        }
        NSLayoutConstraint.activate([
            segmentsView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            segmentsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            segmentsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            segmentsView.heightAnchor.constraint(equalToConstant: 20),
            segmentsStack.centerXAnchor.constraint(equalTo: segmentsView.centerXAnchor),
            segmentsStack.centerYAnchor.constraint(equalTo: segmentsView.centerYAnchor),
        ])

        // 内容容器（裁剪：滑入滑出的页不许越界）。
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.clipsToBounds = true
        view.addSubview(containerView)

        // 底部主按钮（位置/通知步不用共享按钮，按钮在各自内容里）。
        footerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerView)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.backgroundColor = BearyOnboardingPalette.ink
        primaryButton.setTitleColor(.white, for: .normal)
        primaryButton.titleLabel?.font = BearyDynamicType.buttonFont()
        primaryButton.layer.cornerRadius = 12
        primaryButton.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        addPressFeedback(to: primaryButton)
        footerView.addSubview(primaryButton)
        secondaryButton.translatesAutoresizingMaskIntoConstraints = false
        secondaryButton.setTitle("再看一遍", for: .normal)
        secondaryButton.setTitleColor(BearyOnboardingPalette.ink, for: .normal)
        secondaryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        secondaryButton.addTarget(self, action: #selector(replayTapped), for: .touchUpInside)
        footerView.addSubview(secondaryButton)
        let footerHeight = NSLayoutConstraint(item: footerView, attribute: .height, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 64)
        footerHeightConstraint = footerHeight
        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: segmentsView.bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.bottomAnchor.constraint(equalTo: footerView.topAnchor),
            footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            footerHeight,
            primaryButton.topAnchor.constraint(equalTo: footerView.topAnchor),
            primaryButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 24),
            primaryButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -24),
            primaryButton.heightAnchor.constraint(equalToConstant: 52),
            secondaryButton.topAnchor.constraint(equalTo: primaryButton.bottomAnchor, constant: 8),
            secondaryButton.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: 24),
            secondaryButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -24),
            secondaryButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func updateChrome() {
        backButton.isHidden = (step == .p0)
        skipButton.isHidden = (step == .done)
        pageLabel.isHidden = (step == .done)
        if step != .done {
            let text = "\(step.rawValue + 1) / 6"
            let attributed = NSMutableAttributedString(string: text)
            attributed.addAttribute(.kern, value: 13.0 * 0.22, range: NSRange(location: 0, length: attributed.length))
            pageLabel.attributedText = attributed
        }
        segmentsView.isHidden = (step == .done)
        for (index, bar) in segmentBars.enumerated() {
            bar.backgroundColor = (step != .done && index <= step.rawValue) ? BearyOnboardingPalette.ink : BearyOnboardingPalette.track
        }
        let isCardStep = (step == .location || step == .notification)
        footerView.isHidden = isCardStep
        footerHeightConstraint?.constant = {
            switch step {
            case .done: return 116
            case .location, .notification: return 0
            default: return 64
            }
        }()
        switch step {
        case .p0: primaryButton.setTitle("下一步", for: .normal)
        case .p1, .p2, .p3: primaryButton.setTitle("继续", for: .normal)
        case .done: primaryButton.setTitle("进入beary", for: .normal)
        case .location, .notification: break
        }
        secondaryButton.isHidden = (step != .done)
    }

    // MARK: - Navigation

    @objc private func primaryTapped() {
        switch step {
        case .p0: goTo(.p1, direction: .forward, animated: true)
        case .p1: goTo(.p2, direction: .forward, animated: true)
        case .p2: goTo(.p3, direction: .forward, animated: true)
        case .p3: goTo(.location, direction: .forward, animated: true)
        case .location, .notification: break
        case .done: onFinished?()
        }
    }

    @objc private func backTapped() {
        switch step {
        case .p0: break
        case .p1: goTo(.p0, direction: .back, animated: true)
        case .p2: goTo(.p1, direction: .back, animated: true)
        case .p3: goTo(.p2, direction: .back, animated: true)
        case .location: goTo(.p3, direction: .back, animated: true)
        case .notification: goTo(.location, direction: .back, animated: true)
        case .done: goTo(.notification, direction: .back, animated: true)
        }
    }

    @objc private func skipTapped() {
        switch step {
        case .p0, .p1, .p2, .p3:
            goTo(.done, direction: .forward, animated: true)
        case .location:
            goTo(.notification, direction: .forward, animated: true)
        case .notification:
            goTo(.done, direction: .forward, animated: true)
        case .done:
            break
        }
    }

    /// 「再看一遍」：状态全清、从 P0 重走（预览说回登录页；App 内用户已注册，
    /// 回登录页无意义，故回到 P0，见 PR 说明）。
    @objc private func replayTapped() {
        visibility = .selfOnly
        reaction = nil
        locationChoiceMade = false
        locationCityText = "未获取定位"
        locatedCity = nil
        locationGranted = false
        reminderOn = BearyLocalNotifications.shared.isEnabled(.dailyReminder)
        notificationChoiceMade = false
        isRequestingLocation = false
        isRequestingNotification = false
        goTo(.p0, direction: .back, animated: true)
    }

    private func goTo(_ newStep: Step, direction: Direction, animated: Bool) {
        // M4：拖动进行中不响应按钮——否则两套转场同时往容器里装页。
        guard newStep != step, !isTransitioning, !panActive else { return }
        let oldStep = step
        let oldView = currentStepView
        if oldStep == .p3 {
            stopTypewriter()
        }
        step = newStep
        let newView = stepView(for: newStep)
        let width = containerView.bounds.width
        let offset: CGFloat = direction == .forward ? width : -width
        installStepView(newView, initialTransform: CGAffineTransform(translationX: offset, y: 0))
        updateChrome()
        let shouldAnimate = animated && BearyMotion.animated(true)
        guard shouldAnimate else {
            newView.transform = .identity
            oldView?.removeFromSuperview()
            currentStepView = newView
            view.layoutIfNeeded()
            if newStep == .p3 {
                startTypewriter()
            }
            return
        }
        isTransitioning = true
        UIView.animate(withDuration: 0.34, delay: 0, options: [.curveEaseOut], animations: {
            newView.transform = .identity
            oldView?.transform = CGAffineTransform(translationX: -offset, y: 0)
            self.view.layoutIfNeeded()
        }, completion: { [weak self] _ in
            guard let strongSelf = self else { return }
            oldView?.removeFromSuperview()
            strongSelf.currentStepView = newView
            strongSelf.isTransitioning = false
            if newStep == .p3 {
                strongSelf.startTypewriter()
            }
        })
    }

    private func installStepView(_ stepView: UIView, initialTransform: CGAffineTransform) {
        stepView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stepView)
        NSLayoutConstraint.activate([
            stepView.topAnchor.constraint(equalTo: containerView.topAnchor),
            stepView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            stepView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            stepView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        stepView.transform = initialTransform
    }

    private func refreshCurrentStep() {
        guard let oldView = currentStepView else { return }
        let newView = stepView(for: step)
        installStepView(newView, initialTransform: .identity)
        oldView.removeFromSuperview()
        currentStepView = newView
    }

    // MARK: - Interactive pan

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // 横竖不分时先放行：竖向滚动仍由 scroll view 的 pan 接（见 simultaneous），
        // 横向在 changed 里才认方向；竖向拖动时本手势全程无视觉作用、松手即还原。
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return otherGestureRecognizer is UIPanGestureRecognizer
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard !isTransitioning, !panActive else { return }
            // M5：.began 时速度常为 ~0，方向不在这里定——changed 里按累计位移定。
            panPending = true
        case .changed:
            if panPending, !panActive {
                // 转场进行中先等着（按钮刚点了翻页），转场完再认方向。
                guard !isTransitioning else { return }
                let translation = gesture.translation(in: containerView)
                // 竖向为主：本手势不认，交给 scroll view。
                if abs(translation.y) > abs(translation.x), abs(translation.y) > 10 {
                    panPending = false
                    return
                }
                guard abs(translation.x) > 10 else { return }
                let direction: Direction = translation.x < 0 ? .forward : .back
                let targetRaw = direction == .forward ? step.rawValue + 1 : step.rawValue - 1
                guard let targetStep = Step(rawValue: targetRaw) else {
                    panPending = false
                    return
                }
                let width = containerView.bounds.width
                let targetView = stepView(for: targetStep)
                let offset: CGFloat = direction == .forward ? width : -width
                installStepView(targetView, initialTransform: CGAffineTransform(translationX: offset, y: 0))
                panActive = true
                panTargetStep = targetStep
                panTargetDirection = direction
                panTargetView = targetView
                panPending = false
            }
            guard panActive, let direction = panTargetDirection, let targetView = panTargetView, let currentView = currentStepView else { return }
            let width = containerView.bounds.width
            let translation = gesture.translation(in: containerView).x
            var clamped = translation
            if direction == .forward {
                clamped = min(0, max(-width, translation))
            } else {
                clamped = max(0, min(width, translation))
            }
            currentView.transform = CGAffineTransform(translationX: clamped, y: 0)
            let targetOffset: CGFloat = direction == .forward ? width : -width
            targetView.transform = CGAffineTransform(translationX: targetOffset + clamped, y: 0)
        case .ended, .cancelled, .failed:
            panPending = false
            guard panActive else { return }
            settlePan(gesture)
        default:
            break
        }
    }

    private func settlePan(_ gesture: UIPanGestureRecognizer) {
        guard let targetStep = panTargetStep, let direction = panTargetDirection, let targetView = panTargetView, let currentView = currentStepView else {
            panActive = false
            return
        }
        let width = containerView.bounds.width
        let translation = gesture.translation(in: containerView).x
        let velocity = gesture.velocity(in: containerView).x
        let progress = abs(translation) / max(width, 1)
        let shouldComplete: Bool
        if direction == .forward {
            shouldComplete = progress > (1.0 / 3.0) || velocity < -600
        } else {
            shouldComplete = progress > (1.0 / 3.0) || velocity > 600
        }
        panActive = false
        panTargetStep = nil
        panTargetDirection = nil
        panTargetView = nil
        if shouldComplete {
            if step == .p3 {
                stopTypewriter()
            }
            let oldStepView = currentView
            step = targetStep
            updateChrome()
            isTransitioning = true
            let duration = BearyMotion.animated(true) ? 0.26 : 0
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut], animations: {
                targetView.transform = .identity
                currentView.transform = CGAffineTransform(translationX: direction == .forward ? -width : width, y: 0)
                self.view.layoutIfNeeded()
            }, completion: { [weak self] _ in
                guard let strongSelf = self else { return }
                oldStepView.removeFromSuperview()
                strongSelf.currentStepView = targetView
                strongSelf.isTransitioning = false
                if targetStep == .p3 {
                    strongSelf.startTypewriter()
                }
            })
        } else {
            isTransitioning = true
            let duration = BearyMotion.animated(true) ? 0.26 : 0
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut], animations: {
                targetView.transform = CGAffineTransform(translationX: direction == .forward ? width : -width, y: 0)
                currentView.transform = .identity
            }, completion: { [weak self] _ in
                targetView.removeFromSuperview()
                self?.isTransitioning = false
                // 位置/通知步可能在拖动期间拿到异步结果（定位/权限），复位后刷新一次
                //（P3 不刷新：打字机状态在 VC 里，重建会丢已打字数）。
                if let strongSelf = self, strongSelf.step == .location || strongSelf.step == .notification {
                    strongSelf.refreshCurrentStep()
                }
            })
        }
    }

    // MARK: - Step views

    private func stepView(for targetStep: Step) -> UIView {
        switch targetStep {
        case .p0: return makeP0View()
        case .p1: return makeP1View()
        case .p2: return makeP2View()
        case .p3: return makeP3View()
        case .location: return makeLocationView()
        case .notification: return makeNotificationView()
        case .done: return makeDoneView()
        }
    }

    /// 每步一个纵向滚动容器；内容短的卡片步（位置/通知/结束）垂直居中，
    /// 内容超高时照常滚动（小屏兜底）。
    private func makeStepScrollView(centered: Bool) -> (scrollView: UIScrollView, stack: UIStackView) {
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.backgroundColor = .clear
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        contentView.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),
        ]
        if centered {
            let centerY = stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
            centerY.priority = UILayoutPriority(rawValue: 750)
            constraints.append(centerY)
            constraints.append(stack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 16))
        } else {
            constraints.append(stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8))
        }
        NSLayoutConstraint.activate(constraints)
        return (scrollView, stack)
    }

    private func makeTitleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = attributed(text, font: .onboardingSerif(ofSize: 30), color: BearyOnboardingPalette.ink, lineHeightMultiple: 1.35)
        return label
    }

    private func makeLeadLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.attributedText = attributed(text, font: UIFont.systemFont(ofSize: 16), color: BearyOnboardingPalette.ink2, lineHeightMultiple: 1.6)
        return label
    }

    private func makeHeadingLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.attributedText = attributed(text, font: UIFont.systemFont(ofSize: 23, weight: .semibold), color: BearyOnboardingPalette.ink, lineHeightMultiple: 1.4)
        return label
    }

    private func makeSubLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.attributedText = attributed(text, font: UIFont.systemFont(ofSize: 14), color: BearyOnboardingPalette.muted, lineHeightMultiple: 1.6)
        return label
    }

    private func attributed(_ text: String, font: UIFont, color: UIColor, lineHeightMultiple: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
    }

    private func spacer(_ height: CGFloat) -> UIView {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private func addPressFeedback(to button: UIButton) {
        button.addTarget(self, action: #selector(blackButtonTouchDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(blackButtonTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc private func blackButtonTouchDown(_ sender: UIButton) {
        UIView.animate(withDuration: BearyMotion.micro) { sender.alpha = 0.7 }
    }

    @objc private func blackButtonTouchUp(_ sender: UIButton) {
        UIView.animate(withDuration: BearyMotion.micro) { sender.alpha = 1.0 }
    }

    /// 黑色主按钮（预览口径；与 BearyButton 工厂的 surface2 灰底主钮不同，见 PR 说明）。
    private func makeBlackButton(title: String) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = BearyOnboardingPalette.ink
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = BearyDynamicType.buttonFont()
        button.setTitle(title, for: .normal)
        button.layer.cornerRadius = 12
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        addPressFeedback(to: button)
        return button
    }

    /// 中性 user 图标头像（示例卡用，不放熊头）。
    private func makeNeutralAvatar(diameter: CGFloat) -> UIView {
        let circle = UIView()
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.backgroundColor = BearyOnboardingPalette.blueSoft
        circle.layer.cornerRadius = diameter / 2
        circle.widthAnchor.constraint(equalToConstant: diameter).isActive = true
        circle.heightAnchor.constraint(equalToConstant: diameter).isActive = true
        let glyph = UIImageView(image: UIImage(systemName: "person.fill"))
        glyph.tintColor = BearyOnboardingPalette.muted
        glyph.contentMode = .scaleAspectFit
        glyph.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: diameter * 0.52),
            glyph.heightAnchor.constraint(equalToConstant: diameter * 0.52),
        ])
        return circle
    }

    // MARK: - P0–P3

    private func makeP0View() -> UIView {
        let (scrollView, stack) = makeStepScrollView(centered: false)
        stack.addArrangedSubview(makeTitleLabel("在这里写日记"))
        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(makeLeadLabel("写下今天的事和心情。"))
        stack.addArrangedSubview(spacer(28))
        let emoteWrap = UIView()
        let emote = BearyEmoteView(key: "thinking", animated: true)
        emote.translatesAutoresizingMaskIntoConstraints = false
        emoteWrap.addSubview(emote)
        NSLayoutConstraint.activate([
            emote.widthAnchor.constraint(equalToConstant: 116),
            emote.heightAnchor.constraint(equalToConstant: 116),
            emote.centerXAnchor.constraint(equalTo: emoteWrap.centerXAnchor),
            emote.topAnchor.constraint(equalTo: emoteWrap.topAnchor),
            emote.bottomAnchor.constraint(equalTo: emoteWrap.bottomAnchor),
        ])
        stack.addArrangedSubview(emoteWrap)
        stack.addArrangedSubview(spacer(28))
        stack.addArrangedSubview(makeDiaryMockCard(headerRightText: nil, body: "今天，想记住什么？", bodyFontSize: 18, showFooter: true))
        return scrollView
    }

    private func makeP1View() -> UIView {
        let (scrollView, stack) = makeStepScrollView(centered: false)
        stack.addArrangedSubview(makeTitleLabel("写下来，也选好谁能看。"))
        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(makeLeadLabel("发布前，确认这篇日记的可见范围。"))
        stack.addArrangedSubview(spacer(24))
        stack.addArrangedSubview(makeDiaryMockCard(headerRightText: nil, body: "今天，想记住什么？", bodyFontSize: 16, showFooter: false))
        stack.addArrangedSubview(spacer(20))
        stack.addArrangedSubview(makeVisibilityCard())
        return scrollView
    }

    private func makeP2View() -> UIView {
        let (scrollView, stack) = makeStepScrollView(centered: false)
        stack.addArrangedSubview(makeTitleLabel("用小熊回应日记。"))
        stack.addArrangedSubview(spacer(12))
        // 预览里导语与标题是同一句，原文保留（见 PR 说明）。
        stack.addArrangedSubview(makeLeadLabel("用小熊回应这篇日记。"))
        stack.addArrangedSubview(spacer(24))
        stack.addArrangedSubview(makeDiaryMockCard(headerRightText: "仅自己可见", body: "傍晚沿着河边走了一圈，风很舒服。", bodyFontSize: 16, showFooter: false))
        stack.addArrangedSubview(spacer(20))
        reactionChips = []
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 12
        for reactionValue in [Reaction.hug, .love, .cheer] {
            let chip = ReactionChipView(reaction: reactionValue, selected: reaction == reactionValue)
            chip.addTarget(self, action: #selector(reactionChipTapped(_:)), for: .touchUpInside)
            row.addArrangedSubview(chip)
            reactionChips.append(chip)
        }
        stack.addArrangedSubview(row)
        stack.addArrangedSubview(spacer(12))
        let noteLabel = UILabel()
        noteLabel.numberOfLines = 0
        noteLabel.textAlignment = .center
        noteLabel.font = UIFont.systemFont(ofSize: 13)
        noteLabel.textColor = BearyOnboardingPalette.muted
        noteLabel.text = reactionNoteText()
        reactionNoteLabel = noteLabel
        stack.addArrangedSubview(noteLabel)
        return scrollView
    }

    private func reactionNoteText() -> String {
        if let reactionValue = reaction {
            return "已用「\(reactionValue.displayName)」回应这篇日记"
        }
        return "点一张小熊，试试回应"
    }

    @objc private func reactionChipTapped(_ sender: ReactionChipView) {
        // 再点一次取消选中。
        if reaction == sender.reaction {
            reaction = nil
        } else {
            reaction = sender.reaction
        }
        for chip in reactionChips {
            chip.setSelected(chip.reaction == reaction)
        }
        reactionNoteLabel?.text = reactionNoteText()
    }

    private func makeP3View() -> UIView {
        let (scrollView, stack) = makeStepScrollView(centered: false)
        stack.addArrangedSubview(makeTitleLabel("从今天的一小件事开始。"))
        stack.addArrangedSubview(spacer(12))
        stack.addArrangedSubview(makeLeadLabel("想写什么，就写什么。"))
        stack.addArrangedSubview(spacer(24))
        stack.addArrangedSubview(makePaperMock())
        return scrollView
    }

    /// 示例日记卡：App 内真实日记卡片布局（头像＋名字＋时间／正文／地址＋天气脚）。
    /// 名字/地点/天气均为预览 mock 值（Teddy／上海市／18° 晴），不是用户数据。
    private func makeDiaryMockCard(headerRightText: String?, body: String, bodyFontSize: CGFloat, showFooter: Bool) -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyOnboardingPalette.cardBackground
        card.layer.borderColor = BearyOnboardingPalette.line.cgColor
        card.layer.borderWidth = 1
        card.layer.cornerRadius = 16
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 12
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        // 头行：头像＋名字／时间，右端可选文字（如「仅自己可见」）。
        let headerRow = UIStackView()
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 10
        headerRow.addArrangedSubview(makeNeutralAvatar(diameter: 38))
        let nameTime = UIStackView()
        nameTime.axis = .vertical
        nameTime.spacing = 2
        let nameLabel = UILabel()
        nameLabel.font = BearyDynamicType.cardTitleFont()
        nameLabel.textColor = BearyOnboardingPalette.ink
        nameLabel.text = "Teddy"
        nameTime.addArrangedSubview(nameLabel)
        let timeLabel = UILabel()
        timeLabel.font = BearyDynamicType.captionFont()
        timeLabel.textColor = BearyOnboardingPalette.muted
        timeLabel.text = "今天 21:00"
        nameTime.addArrangedSubview(timeLabel)
        headerRow.addArrangedSubview(nameTime)
        let headerSpacer = UIView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(headerSpacer)
        if let rightText = headerRightText {
            let rightLabel = UILabel()
            rightLabel.font = BearyDynamicType.captionFont()
            rightLabel.textColor = BearyOnboardingPalette.muted
            rightLabel.text = rightText
            headerRow.addArrangedSubview(rightLabel)
        }
        stack.addArrangedSubview(headerRow)
        // 正文。
        let bodyLabel = UILabel()
        bodyLabel.numberOfLines = 0
        bodyLabel.attributedText = attributed(body, font: UIFont.systemFont(ofSize: bodyFontSize), color: BearyOnboardingPalette.ink, lineHeightMultiple: 1.55)
        stack.addArrangedSubview(bodyLabel)
        // 脚：地址＋天气（仅 P0）。
        if showFooter {
            let footerRow = UIStackView()
            footerRow.axis = .horizontal
            footerRow.alignment = .center
            footerRow.spacing = 4
            let pinImage = UIImageView(image: UIImage(systemName: "mappin"))
            pinImage.tintColor = BearyOnboardingPalette.muted
            pinImage.contentMode = .scaleAspectFit
            pinImage.widthAnchor.constraint(equalToConstant: 12).isActive = true
            pinImage.heightAnchor.constraint(equalToConstant: 12).isActive = true
            footerRow.addArrangedSubview(pinImage)
            let cityLabel = UILabel()
            cityLabel.font = BearyDynamicType.captionFont()
            cityLabel.textColor = BearyOnboardingPalette.muted
            cityLabel.text = "上海市"
            footerRow.addArrangedSubview(cityLabel)
            let gap = UIView()
            gap.translatesAutoresizingMaskIntoConstraints = false
            gap.widthAnchor.constraint(equalToConstant: 12).isActive = true
            footerRow.addArrangedSubview(gap)
            let sunImage = UIImageView(image: UIImage(systemName: "sun.max.fill"))
            sunImage.tintColor = BearyOnboardingPalette.orange
            sunImage.contentMode = .scaleAspectFit
            sunImage.widthAnchor.constraint(equalToConstant: 12).isActive = true
            sunImage.heightAnchor.constraint(equalToConstant: 12).isActive = true
            footerRow.addArrangedSubview(sunImage)
            let weatherLabel = UILabel()
            weatherLabel.font = BearyDynamicType.captionFont()
            weatherLabel.textColor = BearyOnboardingPalette.muted
            weatherLabel.text = "18° 晴"
            footerRow.addArrangedSubview(weatherLabel)
            let footerSpacer = UIView()
            footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            footerRow.addArrangedSubview(footerSpacer)
            stack.addArrangedSubview(footerRow)
        }
        return card
    }

    private func makeVisibilityCard() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyOnboardingPalette.cardBackground
        card.layer.borderColor = BearyOnboardingPalette.line.cgColor
        card.layer.borderWidth = 1
        card.layer.cornerRadius = 16
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        let options: [(Visibility, String, String)] = [
            (.public, "公开", "所有人都能看到这篇日记"),
            (.friends, NSLocalizedString("onboarding.visibility.friends_only_title", comment: ""), NSLocalizedString("onboarding.visibility.friends_only_description", comment: "")),
            (.selfOnly, "仅自己可见", "只有你自己能看到"),
        ]
        for (index, option) in options.enumerated() {
            if index > 0 {
                let hairline = UIView()
                hairline.translatesAutoresizingMaskIntoConstraints = false
                hairline.backgroundColor = BearyOnboardingPalette.line2
                hairline.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
                stack.addArrangedSubview(hairline)
            }
            let row = VisibilityRowView(title: option.1, subtitle: option.2, selected: visibility == option.0)
            row.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(visibilityRowTapped(_:))))
            row.bearyAddRowPressFeedback()
            row.tag = index
            stack.addArrangedSubview(row)
        }
        return card
    }

    @objc private func visibilityRowTapped(_ sender: UITapGestureRecognizer) {
        guard let row = sender.view as? VisibilityRowView else { return }
        let options: [Visibility] = [.public, .friends, .selfOnly]
        guard row.tag >= 0, row.tag < options.count else { return }
        visibility = options[row.tag]
        // 重建当前步即刷新三行选中态。
        refreshCurrentStep()
    }

    /// P3 纸面：首行「今天」常驻＋后文逐字慢打（橙色光标 1.1s 硬闪），下附三横线。
    private func makePaperMock() -> UIView {
        let paper = UIView()
        paper.translatesAutoresizingMaskIntoConstraints = false
        paper.backgroundColor = BearyOnboardingPalette.cardBackground
        paper.layer.borderColor = BearyOnboardingPalette.line.cgColor
        paper.layer.borderWidth = 1
        paper.layer.cornerRadius = 16
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 24
        paper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: paper.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -20),
        ])
        // 首行：今天（常驻）＋逐字后文＋光标。
        let lineRow = UIStackView()
        lineRow.axis = .horizontal
        lineRow.alignment = .center
        lineRow.spacing = 2
        let todayLabel = UILabel()
        todayLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        todayLabel.textColor = BearyOnboardingPalette.ink
        todayLabel.text = "今天"
        lineRow.addArrangedSubview(todayLabel)
        let typed = UILabel()
        typed.font = UIFont.systemFont(ofSize: 16)
        typed.textColor = BearyOnboardingPalette.ink
        typed.numberOfLines = 0
        typed.text = ""
        typedLabel = typed
        lineRow.addArrangedSubview(typed)
        let caret = UIView()
        caret.translatesAutoresizingMaskIntoConstraints = false
        caret.backgroundColor = BearyOnboardingPalette.orange
        caret.widthAnchor.constraint(equalToConstant: 2).isActive = true
        caret.heightAnchor.constraint(equalToConstant: 20).isActive = true
        lineRow.addArrangedSubview(caret)
        let caretBlink = CAKeyframeAnimation(keyPath: "opacity")
        caretBlink.values = [1, 1, 0, 0]
        caretBlink.keyTimes = [0, 0.5, 0.5, 1]
        caretBlink.duration = 1.1
        caretBlink.repeatCount = .infinity
        caret.layer.add(caretBlink, forKey: "blink")
        stack.addArrangedSubview(lineRow)
        // 三横线：全、全、45%。
        for (index, fraction) in [1.0, 1.0, 0.45].enumerated() {
            let wrap = UIView()
            wrap.translatesAutoresizingMaskIntoConstraints = false
            if index > 0 {
                // 横线间距由 stack.spacing 兜底；首条与首行同距。
            }
            let hairline = UIView()
            hairline.translatesAutoresizingMaskIntoConstraints = false
            hairline.backgroundColor = BearyOnboardingPalette.line
            wrap.addSubview(hairline)
            NSLayoutConstraint.activate([
                hairline.topAnchor.constraint(equalTo: wrap.topAnchor),
                hairline.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
                hairline.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
                hairline.heightAnchor.constraint(equalToConstant: 1),
            ])
            if fraction < 1.0 {
                hairline.widthAnchor.constraint(equalTo: wrap.widthAnchor, multiplier: fraction).isActive = true
            } else {
                hairline.trailingAnchor.constraint(equalTo: wrap.trailingAnchor).isActive = true
            }
            stack.addArrangedSubview(wrap)
        }
        return paper
    }

    // MARK: - P3 typewriter

    private func startTypewriter() {
        stopTypewriter()
        typedCount = 0
        typedLabel?.text = ""
        if UIAccessibility.isReduceMotionEnabled {
            typedLabel?.text = Self.typewriterSuffix
            typedCount = Self.typewriterSuffix.count
            return
        }
        scheduleNextTypewriterChar(after: 0.35)
    }

    private func stopTypewriter() {
        typewriterTimer?.invalidate()
        typewriterTimer = nil
    }

    private func scheduleNextTypewriterChar(after delay: TimeInterval) {
        typewriterTimer?.invalidate()
        typewriterTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.typeNextChar()
        }
    }

    private func typeNextChar() {
        guard let label = typedLabel, typedCount < Self.typewriterSuffix.count else { return }
        let index = Self.typewriterSuffix.index(Self.typewriterSuffix.startIndex, offsetBy: typedCount)
        let char = Self.typewriterSuffix[index]
        label.text = (label.text ?? "") + String(char)
        typedCount += 1
        guard typedCount < Self.typewriterSuffix.count else { return }
        var delay = TimeInterval.random(in: 0.15...0.28)
        if char == "，" || char == "、" {
            delay += 0.32
        }
        if char == "。" || char == "！" || char == "？" {
            delay += 0.48
        }
        scheduleNextTypewriterChar(after: delay)
    }

    // MARK: - Location step

    private func makeLocationView() -> UIView {
        let (scrollView, stack) = makeStepScrollView(centered: true)
        let mapWrap = UIView()
        let mapView = FoldedMapView()
        mapView.translatesAutoresizingMaskIntoConstraints = false
        mapWrap.addSubview(mapView)
        NSLayoutConstraint.activate([
            mapView.widthAnchor.constraint(equalToConstant: 150),
            mapView.heightAnchor.constraint(equalToConstant: 118),
            mapView.centerXAnchor.constraint(equalTo: mapWrap.centerXAnchor),
            mapView.topAnchor.constraint(equalTo: mapWrap.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: mapWrap.bottomAnchor),
        ])
        stack.addArrangedSubview(mapWrap)
        stack.addArrangedSubview(spacer(24))
        stack.addArrangedSubview(makeHeadingLabel("写日记时自动带上地点？"))
        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(makeSubLabel("开启后，每篇日记会自动带上地点和天气；\n不开也可以每次手动添加。"))
        stack.addArrangedSubview(spacer(24))
        // 城市只读框。
        let field = UIView()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.backgroundColor = BearyOnboardingPalette.cardBackground
        field.layer.borderColor = BearyOnboardingPalette.line.cgColor
        field.layer.borderWidth = 1
        field.layer.cornerRadius = 14
        field.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let fieldLabel = UILabel()
        fieldLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldLabel.font = UIFont.systemFont(ofSize: 17)
        fieldLabel.textColor = BearyOnboardingPalette.ink
        fieldLabel.textAlignment = .center
        fieldLabel.text = locationCityText
        field.addSubview(fieldLabel)
        NSLayoutConstraint.activate([
            fieldLabel.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 12),
            fieldLabel.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: -12),
            fieldLabel.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
        stack.addArrangedSubview(field)
        stack.addArrangedSubview(spacer(12))
        // 点击自动定位。
        let locateButton = UIButton(type: .system)
        locateButton.translatesAutoresizingMaskIntoConstraints = false
        locateButton.setImage(UIImage(systemName: "mappin"), for: .normal)
        locateButton.setTitle("点击自动定位", for: .normal)
        locateButton.setTitleColor(BearyOnboardingPalette.linkBlue, for: .normal)
        locateButton.tintColor = BearyOnboardingPalette.linkBlue
        locateButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        locateButton.imageView?.contentMode = .scaleAspectFit
        locateButton.addTarget(self, action: #selector(locateTapped), for: .touchUpInside)
        locateButton.isEnabled = !isRequestingLocation
        let locateWrap = UIView()
        locateWrap.addSubview(locateButton)
        NSLayoutConstraint.activate([
            locateButton.centerXAnchor.constraint(equalTo: locateWrap.centerXAnchor),
            locateButton.topAnchor.constraint(equalTo: locateWrap.topAnchor),
            locateButton.bottomAnchor.constraint(equalTo: locateWrap.bottomAnchor),
            locateButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        stack.addArrangedSubview(locateWrap)
        stack.addArrangedSubview(spacer(20))
        let primary = makeBlackButton(title: locationChoiceMade ? "继续" : "开启定位")
        primary.addTarget(self, action: #selector(locationPrimaryTapped), for: .touchUpInside)
        primary.isEnabled = !isRequestingLocation
        stack.addArrangedSubview(primary)
        return scrollView
    }

    @objc private func locateTapped() {
        requestLocation()
    }

    @objc private func locationPrimaryTapped() {
        if locationChoiceMade {
            goTo(.notification, direction: .forward, animated: true)
        } else {
            requestLocation()
        }
    }

    private func requestLocation() {
        guard !isRequestingLocation else { return }
        isRequestingLocation = true
        locationGeneration += 1
        let generation = locationGeneration
        if !isTransitioning && !panActive {
            refreshCurrentStep()
        }
        BearyOneShotLocation.request { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 旧请求晚到了：新请求已在跑，别动它的状态。
                guard generation == strongSelf.locationGeneration else { return }
                strongSelf.isRequestingLocation = false
                switch result {
                case .coordinate(let latitude, let longitude):
                    strongSelf.locationGranted = true
                    strongSelf.reverseGeocode(latitude: latitude, longitude: longitude, generation: generation)
                case .denied, .unavailable:
                    strongSelf.locationGranted = false
                    strongSelf.locationChoiceMade = true
                    strongSelf.locationCityText = "未获取定位"
                    strongSelf.refreshLocationStepIfVisible()
                }
            }
        }
    }

    private func reverseGeocode(latitude: Double, longitude: Double, generation: Int) {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                // 旧请求或已离开位置步：结果丢弃，不写 locatedCity（表单不该用
                // 用户没在位置步上确认过的城市预填）。
                guard generation == strongSelf.locationGeneration, strongSelf.step == .location else { return }
                let place = placemarks?.first
                // 直辖市 locality 常为空，区在 subLocality 里；match 层会把直辖市
                // 的地区名本身当城市（M8）。
                let matched = BearyCityData.match(country: place?.country, region: place?.administrativeArea, city: place?.locality ?? place?.subLocality)
                strongSelf.locationChoiceMade = true
                if let matchedCity = matched {
                    if let region = matchedCity.region, let city = matchedCity.city {
                        strongSelf.locatedCity = (matchedCity.country, region, city)
                    }
                    strongSelf.locationCityText = matchedCity.city ?? matchedCity.region ?? matchedCity.country
                } else {
                    strongSelf.locationCityText = "未获取定位"
                }
                strongSelf.refreshLocationStepIfVisible()
            }
        }
    }

    private func refreshLocationStepIfVisible() {
        guard step == .location, !isTransitioning, !panActive else { return }
        refreshCurrentStep()
    }

    // MARK: - Notification step

    private func makeNotificationView() -> UIView {
        let (scrollView, stack) = makeStepScrollView(centered: true)
        let bellWrap = UIView()
        let bellView = NotificationBellView()
        bellView.translatesAutoresizingMaskIntoConstraints = false
        bellWrap.addSubview(bellView)
        NSLayoutConstraint.activate([
            bellView.widthAnchor.constraint(equalToConstant: 96),
            bellView.heightAnchor.constraint(equalToConstant: 104),
            bellView.centerXAnchor.constraint(equalTo: bellWrap.centerXAnchor),
            bellView.topAnchor.constraint(equalTo: bellWrap.topAnchor),
            bellView.bottomAnchor.constraint(equalTo: bellWrap.bottomAnchor),
        ])
        stack.addArrangedSubview(bellWrap)
        stack.addArrangedSubview(spacer(20))
        stack.addArrangedSubview(makeHeadingLabel("每天提醒你写日记"))
        stack.addArrangedSubview(spacer(10))
        stack.addArrangedSubview(makeSubLabel("到了时间，轻轻提醒你一句。"))
        stack.addArrangedSubview(spacer(24))
        stack.addArrangedSubview(makeNotificationRowsCard())
        stack.addArrangedSubview(spacer(20))
        let primary = makeBlackButton(title: notificationChoiceMade ? "继续" : "开启提醒")
        primary.addTarget(self, action: #selector(notificationPrimaryTapped), for: .touchUpInside)
        primary.isEnabled = !isRequestingNotification
        stack.addArrangedSubview(primary)
        return scrollView
    }

    private func makeNotificationRowsCard() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyOnboardingPalette.cardBackground
        card.layer.borderColor = BearyOnboardingPalette.line.cgColor
        card.layer.borderWidth = 1
        card.layer.cornerRadius = 16
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        // 行 1：每天 21:00 提醒（默认开）。
        let row1 = UIView()
        row1.translatesAutoresizingMaskIntoConstraints = false
        let texts1 = UIStackView()
        texts1.translatesAutoresizingMaskIntoConstraints = false
        texts1.axis = .vertical
        texts1.spacing = 3
        let title1 = UILabel()
        title1.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        title1.textColor = BearyOnboardingPalette.ink
        title1.text = "每天 21:00 提醒"
        texts1.addArrangedSubview(title1)
        let sub1 = UILabel()
        sub1.font = UIFont.systemFont(ofSize: 13)
        sub1.textColor = BearyOnboardingPalette.muted
        sub1.text = "每天提醒写日记"
        texts1.addArrangedSubview(sub1)
        row1.addSubview(texts1)
        let reminderSwitch = UISwitch()
        reminderSwitch.translatesAutoresizingMaskIntoConstraints = false
        reminderSwitch.onTintColor = BearyOnboardingPalette.switchGreen
        reminderSwitch.isOn = reminderOn
        reminderSwitch.addTarget(self, action: #selector(reminderSwitchChanged(_:)), for: .valueChanged)
        row1.addSubview(reminderSwitch)
        NSLayoutConstraint.activate([
            row1.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            texts1.leadingAnchor.constraint(equalTo: row1.leadingAnchor, constant: 16),
            texts1.centerYAnchor.constraint(equalTo: row1.centerYAnchor),
            texts1.trailingAnchor.constraint(lessThanOrEqualTo: reminderSwitch.leadingAnchor, constant: -12),
            reminderSwitch.trailingAnchor.constraint(equalTo: row1.trailingAnchor, constant: -16),
            reminderSwitch.centerYAnchor.constraint(equalTo: row1.centerYAnchor),
        ])
        stack.addArrangedSubview(row1)
        let hairline = UIView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        hairline.backgroundColor = BearyOnboardingPalette.line2
        hairline.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        stack.addArrangedSubview(hairline)
        // 行 2：好友通知提醒（推送未上线，置灰、无开关）。
        let row2 = UIView()
        row2.translatesAutoresizingMaskIntoConstraints = false
        row2.alpha = 0.45
        let texts2 = UIStackView()
        texts2.translatesAutoresizingMaskIntoConstraints = false
        texts2.axis = .vertical
        texts2.spacing = 3
        let title2 = UILabel()
        title2.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        title2.textColor = BearyOnboardingPalette.ink
        title2.text = "好友通知提醒"
        texts2.addArrangedSubview(title2)
        let sub2 = UILabel()
        sub2.font = UIFont.systemFont(ofSize: 13)
        sub2.textColor = BearyOnboardingPalette.muted
        sub2.text = "随时接收朋友的喜欢和评论"
        texts2.addArrangedSubview(sub2)
        row2.addSubview(texts2)
        let tagLabel = UILabel()
        tagLabel.translatesAutoresizingMaskIntoConstraints = false
        tagLabel.font = UIFont.systemFont(ofSize: 11)
        tagLabel.textColor = BearyOnboardingPalette.muted
        tagLabel.backgroundColor = BearyOnboardingPalette.tagBackground
        tagLabel.layer.cornerRadius = 8
        tagLabel.clipsToBounds = true
        tagLabel.textAlignment = .center
        tagLabel.text = "推送上线后开启"
        row2.addSubview(tagLabel)
        NSLayoutConstraint.activate([
            row2.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
            texts2.leadingAnchor.constraint(equalTo: row2.leadingAnchor, constant: 16),
            texts2.centerYAnchor.constraint(equalTo: row2.centerYAnchor),
            texts2.trailingAnchor.constraint(lessThanOrEqualTo: tagLabel.leadingAnchor, constant: -12),
            tagLabel.trailingAnchor.constraint(equalTo: row2.trailingAnchor, constant: -16),
            tagLabel.centerYAnchor.constraint(equalTo: row2.centerYAnchor),
            tagLabel.heightAnchor.constraint(equalToConstant: 24),
        ])
        stack.addArrangedSubview(row2)
        return card
    }

    @objc private func reminderSwitchChanged(_ sender: UISwitch) {
        reminderOn = sender.isOn
    }

    /// 选完权限不自动跳页：系统框出结果后停在本页，按钮变「继续」才进。
    @objc private func notificationPrimaryTapped() {
        if notificationChoiceMade {
            BearyLocalNotifications.shared.setEnabled(reminderOn, for: .dailyReminder)
            goTo(.done, direction: .forward, animated: true)
            return
        }
        requestNotificationPermission()
    }

    private func requestNotificationPermission() {
        guard !isRequestingNotification else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                if settings.authorizationStatus == .notDetermined {
                    strongSelf.isRequestingNotification = true
                    strongSelf.refreshNotificationStepIfVisible()
                    BearyLocalNotifications.shared.requestAuthorizationIfNeeded(
                        options: [.alert, .sound, .badge],
                        completion: { _ in
                            strongSelf.isRequestingNotification = false
                            strongSelf.notificationChoiceMade = true
                            strongSelf.refreshNotificationStepIfVisible()
                        },
                        onDenied: {
                            // M2：被拒时提醒开关同步关掉——否则设置页读到开、系统却不发通知，两边不一致。
                            strongSelf.reminderOn = false
                        }
                    )
                } else {
                    strongSelf.notificationChoiceMade = true
                    strongSelf.refreshNotificationStepIfVisible()
                }
            }
        }
    }

    private func refreshNotificationStepIfVisible() {
        guard step == .notification, !isTransitioning, !panActive else { return }
        refreshCurrentStep()
    }

    // MARK: - Done step

    private func makeDoneView() -> UIView {
        let (scrollView, stack) = makeStepScrollView(centered: true)
        let checkWrap = UIView()
        let checkCircle = UIView()
        checkCircle.translatesAutoresizingMaskIntoConstraints = false
        checkCircle.layer.borderColor = BearyOnboardingPalette.ink.cgColor
        checkCircle.layer.borderWidth = 1.5
        checkCircle.layer.cornerRadius = 42
        checkWrap.addSubview(checkCircle)
        let checkLabel = UILabel()
        checkLabel.translatesAutoresizingMaskIntoConstraints = false
        checkLabel.font = UIFont.systemFont(ofSize: 34, weight: .semibold)
        checkLabel.textColor = BearyOnboardingPalette.ink
        checkLabel.textAlignment = .center
        checkLabel.text = "✓"
        checkCircle.addSubview(checkLabel)
        NSLayoutConstraint.activate([
            checkCircle.widthAnchor.constraint(equalToConstant: 84),
            checkCircle.heightAnchor.constraint(equalToConstant: 84),
            checkCircle.centerXAnchor.constraint(equalTo: checkWrap.centerXAnchor),
            checkCircle.topAnchor.constraint(equalTo: checkWrap.topAnchor),
            checkCircle.bottomAnchor.constraint(equalTo: checkWrap.bottomAnchor),
            checkLabel.centerXAnchor.constraint(equalTo: checkCircle.centerXAnchor),
            checkLabel.centerYAnchor.constraint(equalTo: checkCircle.centerYAnchor),
        ])
        stack.addArrangedSubview(checkWrap)
        stack.addArrangedSubview(spacer(24))
        let titleLabel = UILabel()
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        titleLabel.attributedText = attributed("设置完成", font: .onboardingSerif(ofSize: 30), color: BearyOnboardingPalette.ink, lineHeightMultiple: 1.35)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(spacer(10))
        let leadLabel = UILabel()
        leadLabel.numberOfLines = 0
        leadLabel.textAlignment = .center
        leadLabel.attributedText = attributed("可以开始写日记了", font: UIFont.systemFont(ofSize: 16), color: BearyOnboardingPalette.ink2, lineHeightMultiple: 1.6)
        stack.addArrangedSubview(leadLabel)
        return scrollView
    }
}

// MARK: - 反应 chip（P2）

private final class ReactionChipView: UIControl {

    let reaction: BearyPostRegistrationOnboardingViewController.Reaction
    private let circleView = UIView()
    private let nameLabel = UILabel()

    init(reaction: BearyPostRegistrationOnboardingViewController.Reaction, selected: Bool) {
        self.reaction = reaction
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .white
        layer.borderColor = BearyOnboardingPalette.line.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 16
        heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        // 子视图不接手势：点按须落到 chip 本身（UIControl 跟踪）才触发选中。
        stack.isUserInteractionEnabled = false
        addSubview(stack)
        circleView.translatesAutoresizingMaskIntoConstraints = false
        circleView.backgroundColor = reaction.circleBackground
        circleView.layer.cornerRadius = 26
        circleView.isUserInteractionEnabled = false
        circleView.widthAnchor.constraint(equalToConstant: 52).isActive = true
        circleView.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let emote = BearyEmoteView(key: reaction.emoteKey, animated: true)
        emote.translatesAutoresizingMaskIntoConstraints = false
        emote.isUserInteractionEnabled = false
        circleView.addSubview(emote)
        NSLayoutConstraint.activate([
            emote.widthAnchor.constraint(equalToConstant: 46),
            emote.heightAnchor.constraint(equalToConstant: 46),
            emote.centerXAnchor.constraint(equalTo: circleView.centerXAnchor),
            emote.centerYAnchor.constraint(equalTo: circleView.centerYAnchor),
        ])
        stack.addArrangedSubview(circleView)
        nameLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        nameLabel.textColor = BearyOnboardingPalette.ink
        nameLabel.text = reaction.displayName
        stack.addArrangedSubview(nameLabel)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setSelected(selected)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        layer.borderColor = selected ? BearyOnboardingPalette.orange.cgColor : BearyOnboardingPalette.line.cgColor
        backgroundColor = selected ? BearyOnboardingPalette.chipSelectedBackground : .white
    }
}

// MARK: - 可见性行（P1）

private final class VisibilityRowView: UIView {

    private let radioOuter = UIView()
    private let radioDot = UIView()

    init(title: String, subtitle: String, selected: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        let row = UIStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        radioOuter.translatesAutoresizingMaskIntoConstraints = false
        radioOuter.layer.borderWidth = 1.5
        radioOuter.layer.cornerRadius = 12
        radioOuter.widthAnchor.constraint(equalToConstant: 24).isActive = true
        radioOuter.heightAnchor.constraint(equalToConstant: 24).isActive = true
        radioDot.translatesAutoresizingMaskIntoConstraints = false
        radioDot.backgroundColor = BearyOnboardingPalette.orange
        radioDot.layer.cornerRadius = 6
        radioOuter.addSubview(radioDot)
        NSLayoutConstraint.activate([
            radioDot.widthAnchor.constraint(equalToConstant: 12),
            radioDot.heightAnchor.constraint(equalToConstant: 12),
            radioDot.centerXAnchor.constraint(equalTo: radioOuter.centerXAnchor),
            radioDot.centerYAnchor.constraint(equalTo: radioOuter.centerYAnchor),
        ])
        row.addArrangedSubview(radioOuter)
        let texts = UIStackView()
        texts.axis = .vertical
        texts.spacing = 3
        let titleLabel = UILabel()
        titleLabel.font = UIFont.systemFont(ofSize: 17)
        titleLabel.textColor = BearyOnboardingPalette.ink
        titleLabel.text = title
        texts.addArrangedSubview(titleLabel)
        let subLabel = UILabel()
        subLabel.font = UIFont.systemFont(ofSize: 13)
        subLabel.textColor = BearyOnboardingPalette.muted
        subLabel.text = subtitle
        texts.addArrangedSubview(subLabel)
        row.addArrangedSubview(texts)
        setSelected(selected)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSelected(_ selected: Bool) {
        radioOuter.layer.borderColor = selected ? BearyOnboardingPalette.orange.cgColor : BearyOnboardingPalette.line.cgColor
        radioDot.isHidden = !selected
    }
}

// MARK: - 折叠地图插画（位置步，线描）

private final class FoldedMapView: UIView {

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let ink = BearyOnboardingPalette.ink
        let orange = BearyOnboardingPalette.orange
        let w = rect.width
        let h = rect.height
        // 外框。
        let outline = UIBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 6)
        ink.setStroke()
        outline.lineWidth = 1.5
        outline.stroke()
        // 两道折痕。
        context.setStrokeColor(ink.withAlphaComponent(0.55).cgColor)
        context.setLineWidth(1)
        for fraction in [1.0 / 3.0, 2.0 / 3.0] {
            let x = 4 + (w - 8) * CGFloat(fraction)
            context.move(to: CGPoint(x: x, y: 6))
            context.addLine(to: CGPoint(x: x, y: h - 6))
            context.strokePath()
        }
        // 图钉。
        let pinCenter = CGPoint(x: w / 2, y: h * 0.30)
        let pinCircle = UIBezierPath(arcCenter: pinCenter, radius: 9, startAngle: 0, endAngle: CGFloat.pi * 2, clockwise: true)
        ink.setFill()
        pinCircle.fill()
        let pinTip = UIBezierPath()
        pinTip.move(to: CGPoint(x: pinCenter.x - 7, y: pinCenter.y + 5))
        pinTip.addLine(to: CGPoint(x: pinCenter.x + 7, y: pinCenter.y + 5))
        pinTip.addLine(to: CGPoint(x: pinCenter.x, y: pinCenter.y + 20))
        pinTip.close()
        pinTip.fill()
        // 橙色中心点。
        let dot = UIBezierPath(arcCenter: CGPoint(x: w / 2, y: h * 0.64), radius: 5, startAngle: 0, endAngle: CGFloat.pi * 2, clockwise: true)
        orange.setFill()
        dot.fill()
    }
}

// MARK: - 铃铛插画（通知步）

private final class NotificationBellView: UIView {

    override init(frame: CGRect) {
        super.init(frame: frame)
        let bellImage = UIImageView(image: UIImage(systemName: "bell.fill"))
        bellImage.tintColor = BearyOnboardingPalette.ink
        bellImage.contentMode = .scaleAspectFit
        bellImage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bellImage)
        // 橙点。
        let dot = UIView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.backgroundColor = BearyOnboardingPalette.orange
        dot.layer.cornerRadius = 6
        addSubview(dot)
        // 减号徽标。
        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.backgroundColor = BearyOnboardingPalette.tagBackground
        badge.layer.cornerRadius = 11
        badge.layer.borderColor = UIColor.white.cgColor
        badge.layer.borderWidth = 2
        addSubview(badge)
        let minusLabel = UILabel()
        minusLabel.translatesAutoresizingMaskIntoConstraints = false
        minusLabel.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        minusLabel.textColor = BearyOnboardingPalette.ink
        minusLabel.textAlignment = .center
        minusLabel.text = "−"
        badge.addSubview(minusLabel)
        NSLayoutConstraint.activate([
            bellImage.centerXAnchor.constraint(equalTo: centerXAnchor),
            bellImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            bellImage.widthAnchor.constraint(equalToConstant: 78),
            bellImage.heightAnchor.constraint(equalToConstant: 84),
            dot.widthAnchor.constraint(equalToConstant: 12),
            dot.heightAnchor.constraint(equalToConstant: 12),
            dot.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            dot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            minusLabel.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            minusLabel.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
