import UIKit

// ===== 登录底 sheet 弹窗（Li 2026-11-02 批准施工：整页登录改弹窗）=====
// 形态：底 sheet + 顶栏同款液态玻璃（BearyGlass.effectView，中性 bg 52% tint；
// iOS 26+ 真 UIGlassEffect，低版本降级系统毛玻璃——与顶栏/底栏同配方）。
// 注意：BearyGlass token 原口径“窗口/弹窗不用系统材质”对登录弹窗有 Li 批准的
// 唯一例外（见 BearyGlass 注释）；不要把本 sheet 的玻璃“统一”回实色底。
// 容器：BearyLoginSheet.make() 只建 sheet 模式登录页、不 present；调用点按原样
// 接回调后再 present（与原整页顺序一致，含 dismiss 调用方与会话守卫）。
// 关闭：关闭钮 / 遮罩点按 / 抓手拖动一律走登录页 cancelFromSheet（= 关闭钮路径，
// 先停倒计时与在途任务、再交 onCancelled），容器不得绕开它直接 dismiss，
// 否则添加账号会话守卫 stays armed。
// 尺寸：高跟内容走（登录页 preferredContentSize），顶留 56pt；宽：<821 全宽，
// ≥821 居中 600（与 App 内容列同口径）；停靠键盘时 sheet 底贴键盘顶，
// 浮动/分屏键盘不动 sheet（页内滚动 inset 已处理遮挡）。
// 拖动：抓手区（sheet 顶 24pt）下滑跟手，超 80pt 或速度 > 600 关闭（BearySheetDrag
// 同口径），否则 0.25s 弹回；动效只走 transform/opacity，减动效直显终值。
// transitioningDelegate 由登录页自身强持有（loginSheetDelegate），随页释放。

enum BearyLoginSheet {
    /// 建一个 sheet 模式登录页（BearyLoginViewController.sheetMode = true +
    /// 底 sheet transitioning），不 present；调用点接完回调后自行 present。
    static func make() -> BearyLoginViewController {
        let vc = BearyLoginViewController()
        vc.sheetMode = true
        let delegate = BearyLoginSheetTransitioningDelegate()
        vc.loginSheetDelegate = delegate
        vc.transitioningDelegate = delegate
        vc.modalPresentationStyle = .custom
        return vc
    }
}

// MARK: - Transitioning delegate

final class BearyLoginSheetTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        BearyLoginSheetPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BearyLoginSheetAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BearyLoginSheetAnimator(isPresenting: false)
    }
}

// MARK: - Presentation controller

private final class BearyLoginSheetPresentationController: UIPresentationController {

    /// 抓手区高：sheet 顶部的玻璃 chrome 区（抓手 10–14 + 余量），登录页内容从其下开始。
    private static let chromeHeight: CGFloat = 24
    /// sheet 顶距容器顶的最小留白。
    private static let topMargin: CGFloat = 56
    /// 宽屏阈值与列宽：与 App 内容列同口径（≥821 居中 600）。
    private static let wideThreshold: CGFloat = 821
    private static let wideSheetWidth: CGFloat = 600
    /// 首帧未算出内容高时的回退内容高（随后 viewDidLayoutSubviews 会纠正）。
    private static let fallbackContentHeight: CGFloat = 666

    private let scrimView = UIView()
    private let shadowView = UIView()
    private let glassView = BearyGlass.effectView(tint: BearyGlass.neutralTint)
    private let grabberView = UIView()
    private let dragStripView = UIView()
    /// 停靠键盘顶边（容器坐标）；浮动/分屏键盘不置位，见 keyboard handlers。
    private var keyboardTopY: CGFloat?
    private var lastShadowBounds: CGRect = .zero

    override init(presentedViewController: UIViewController, presenting presentingViewController: UIViewController?) {
        super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Sheet 整框（含顶 chrome 区）：底贴容器底（或停靠键盘顶），高跟内容走、顶留白钳制。
    private func sheetFrame(for containerBounds: CGRect) -> CGRect {
        let width: CGFloat
        if containerBounds.width >= Self.wideThreshold {
            width = min(Self.wideSheetWidth, containerBounds.width - 32)
        } else {
            width = containerBounds.width
        }
        let x = (containerBounds.width - width) / 2
        let preferred = presentedViewController.preferredContentSize.height
        let contentHeight = preferred > 0
            ? preferred
            : min(Self.fallbackContentHeight, containerBounds.height - Self.topMargin - Self.chromeHeight)
        var sheetHeight = contentHeight + Self.chromeHeight
        let bottomY = keyboardTopY ?? containerBounds.height
        let maxHeight = bottomY - Self.topMargin
        if sheetHeight > maxHeight { sheetHeight = max(0, maxHeight) }
        return CGRect(x: x, y: bottomY - sheetHeight, width: width, height: sheetHeight)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let sheet = sheetFrame(for: container.bounds)
        return CGRect(x: sheet.minX, y: sheet.minY + Self.chromeHeight, width: sheet.width, height: max(0, sheet.height - Self.chromeHeight))
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard let container = containerView, let presentedView = presentedView else { return }
        let sheet = sheetFrame(for: container.bounds)
        scrimView.frame = container.bounds
        // 拖动中不重算 chrome 与 presentedView 的帧：帧 + 平移 transform 混写会跳变；
        // 拖动只改 transform、不改帧，松手复位后帧仍是拖动前那套，无需补算。
        guard presentedView.transform.isIdentity else { return }
        shadowView.frame = sheet
        glassView.frame = sheet
        glassView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        glassView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        glassView.clipsToBounds = true
        grabberView.frame = CGRect(x: sheet.midX - BearySheetChrome.grabberWidth / 2,
                                   y: sheet.minY + BearySheetChrome.grabberTop,
                                   width: BearySheetChrome.grabberWidth,
                                   height: BearySheetChrome.grabberHeight)
        dragStripView.frame = CGRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: Self.chromeHeight)
        presentedView.frame = frameOfPresentedViewInContainerView
        if shadowView.bounds != lastShadowBounds {
            lastShadowBounds = shadowView.bounds
            shadowView.layer.shadowPath = UIBezierPath(roundedRect: shadowView.bounds,
                                                        byRoundingCorners: [.topLeft, .topRight],
                                                        cornerRadii: CGSize(width: BearySheetChrome.topCornerRadius,
                                                                              height: BearySheetChrome.topCornerRadius)).cgPath
        }
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView else { return }
        scrimView.backgroundColor = BearySheetChrome.scrimColor
        scrimView.alpha = 0
        scrimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(scrimTapped)))
        container.addSubview(scrimView)
        shadowView.backgroundColor = .clear
        BearySheetChrome.applyShadow(to: shadowView.layer)
        container.addSubview(shadowView)
        container.addSubview(glassView)
        grabberView.backgroundColor = BearyColors.line
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        container.addSubview(grabberView)
        dragStripView.backgroundColor = .clear
        dragStripView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragPan(_:))))
        container.addSubview(dragStripView)
        // chrome 与 presentedView 同过渡、同距下滑入（与滑入 animator 同 0.25s，
        // 同 sheet 高位移，滑动全程 chrome 与内容不错位）。
        let offscreen = CGAffineTransform(translationX: 0, y: sheetFrame(for: container.bounds).height)
        shadowView.transform = offscreen
        glassView.transform = offscreen
        grabberView.transform = offscreen
        dragStripView.transform = offscreen
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in
                self.scrimView.alpha = 1
                self.shadowView.transform = .identity
                self.glassView.transform = .identity
                self.grabberView.transform = .identity
                self.dragStripView.transform = .identity
            }, completion: nil)
        } else {
            scrimView.alpha = 1
            shadowView.transform = .identity
            glassView.transform = .identity
            grabberView.transform = .identity
            dragStripView.transform = .identity
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed {
            removeChrome()
        }
    }

    override func dismissalTransitionWillBegin() {
        guard let container = containerView else { return }
        let offscreen = CGAffineTransform(translationX: 0, y: sheetFrame(for: container.bounds).height)
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in
                self.scrimView.alpha = 0
                self.shadowView.transform = offscreen
                self.glassView.transform = offscreen
                self.grabberView.transform = offscreen
                self.dragStripView.transform = offscreen
            }, completion: nil)
        } else {
            scrimView.alpha = 0
            shadowView.transform = offscreen
            glassView.transform = offscreen
            grabberView.transform = offscreen
            dragStripView.transform = offscreen
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed {
            removeChrome()
        }
    }

    private func removeChrome() {
        scrimView.removeFromSuperview()
        shadowView.removeFromSuperview()
        glassView.removeFromSuperview()
        grabberView.removeFromSuperview()
        dragStripView.removeFromSuperview()
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        guard let containerView = containerView else { return }
        // 内容高变化（邀请展开/收起、字号档位）时 0.25s 跟帧走。
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
            containerView.layoutIfNeeded()
        })
    }

    // MARK: - 遮罩与拖动

    @objc private func scrimTapped() {
        (presentedViewController as? BearyLoginViewController)?.cancelFromSheet()
    }

    @objc private func dragPan(_ gesture: UIPanGestureRecognizer) {
        guard let container = containerView, let presentedView = presentedView else { return }
        let translation = gesture.translation(in: container).y
        switch gesture.state {
        case .changed:
            let offset = BearySheetDrag.offset(for: translation)
            applyDrag(offset: offset, sheetHeight: sheetFrame(for: container.bounds).height)
        case .ended:
            let velocity = gesture.velocity(in: container).y
            if translation > 80 || velocity > 600 {
                // 不清 transform：dismiss 动效从当前拖位滑下（beginFromCurrentState），
                // 避免先回弹再下滑的跳变。
                (presentedViewController as? BearyLoginViewController)?.cancelFromSheet()
            } else {
                restoreDrag()
            }
        case .cancelled, .failed:
            restoreDrag()
        default:
            break
        }
    }

    private func applyDrag(offset: CGFloat, sheetHeight: CGFloat) {
        let transform = CGAffineTransform(translationX: 0, y: offset)
        presentedView?.transform = transform
        shadowView.transform = transform
        glassView.transform = transform
        grabberView.transform = transform
        dragStripView.transform = transform
        scrimView.alpha = BearySheetDrag.scrimAlpha(forDragOffset: offset, sheetHeight: sheetHeight)
    }

    private func restoreDrag() {
        let restore = {
            self.presentedView?.transform = .identity
            self.shadowView.transform = .identity
            self.glassView.transform = .identity
            self.grabberView.transform = .identity
            self.dragStripView.transform = .identity
            self.scrimView.alpha = 1
        }
        if UIAccessibility.isReduceMotionEnabled {
            restore()
        } else {
            UIView.animate(withDuration: 0.25, animations: restore)
        }
    }

    // MARK: - 键盘

    @objc private func keyboardWillShow(_ note: Notification) {
        updateKeyboardTop(from: note)
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        updateKeyboardTop(from: note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        keyboardTopY = nil
        animateLayoutForKeyboard(note)
    }

    /// 只跟停靠键盘：浮动/分屏键盘（底边未贴容器底）不动 sheet，页内滚动 inset 已处理遮挡。
    private func updateKeyboardTop(from note: Notification) {
        guard let container = containerView,
              let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frameInContainer = container.convert(value.cgRectValue, from: nil)
        guard frameInContainer.maxY >= container.bounds.height - 1 else { return }
        keyboardTopY = frameInContainer.minY
        animateLayoutForKeyboard(note)
    }

    private func animateLayoutForKeyboard(_ note: Notification) {
        guard let container = containerView else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        if UIAccessibility.isReduceMotionEnabled {
            container.layoutIfNeeded()
        } else {
            UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: {
                container.layoutIfNeeded()
            })
        }
    }
}

// MARK: - Slide animator

private final class BearyLoginSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return UIAccessibility.isReduceMotionEnabled ? 0 : 0.25
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        let duration = transitionDuration(using: transitionContext)
        if isPresenting {
            guard let toView = transitionContext.view(forKey: .to),
                  let toVC = transitionContext.viewController(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            container.addSubview(toView)
            toView.frame = transitionContext.finalFrame(for: toVC)
            let offset = toView.bounds.height
            toView.transform = CGAffineTransform(translationX: 0, y: offset)
            if duration == 0 {
                toView.transform = .identity
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                toView.transform = .identity
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            let offset = fromView.bounds.height
            if duration == 0 {
                fromView.transform = CGAffineTransform(translationX: 0, y: offset)
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
                fromView.transform = CGAffineTransform(translationX: 0, y: offset)
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}
