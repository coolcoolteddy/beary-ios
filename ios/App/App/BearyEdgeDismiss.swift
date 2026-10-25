import UIKit

// ===== 全屏 modal 的左边缘右滑返回（第三项：原生返回）=====
// 详情与编辑器是全屏 modal、只能点按钮关闭；这里给两者加上 iOS 原生导航同款手势：
// 从屏幕左边缘右滑 → 视图跟手右移；滑过 35% 宽度或右滑速度够快 → 松手完成关闭；
// 没滑够 → 松手回弹取消。关闭按钮保留。
// 实现：自定义 transitioningDelegate + slide 进出动画（进从右滑入、出向右滑出）+
// UIPercentDrivenInteractiveTransition 驱动交互式关闭。transitioningDelegate 是弱引用，
// 调用方（SceneDelegate）必须强持有本对象直到 dismiss 完成，否则手势中途失效。
// 注意：只接全屏 modal；桌面式居中 640 编辑器模态不贴屏幕边缘，边缘手势在它身上物理上无法触发，关闭仍靠取消按钮。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

final class BearyEdgeDismissController: NSObject, UIViewControllerTransitioningDelegate {

    private weak var presentedVC: UIViewController?
    private var interaction: UIPercentDrivenInteractiveTransition?

    /// 把边缘手势挂到已呈现容器的 view 上（详情是 nav 容器的 view，编辑器是自身 view）。
    /// 必须在 present 之前调用，且调用方要一直强持有本对象。
    func attach(to presented: UIViewController) {
        presentedVC = presented
        let pan = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgePan(_:)))
        pan.edges = .left
        presented.view.addGestureRecognizer(pan)
    }

    // MARK: - UIViewControllerTransitioningDelegate

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearySlideTransitionAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearySlideTransitionAnimator(isPresenting: false)
    }

    func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        return interaction
    }

    // MARK: - 手势

    @objc private func handleEdgePan(_ pan: UIScreenEdgePanGestureRecognizer) {
        guard let presented = presentedVC, let view = pan.view else { return }
        let width = view.bounds.width
        guard width > 0 else { return }
        let progress = min(max(pan.translation(in: view).x / width, 0), 1)
        switch pan.state {
        case .began:
            interaction = UIPercentDrivenInteractiveTransition()
            presented.dismiss(animated: true)
        case .changed:
            interaction?.update(progress)
        case .cancelled, .failed:
            // U24：.failed 与 .cancelled 同处理——清理交互式过渡对象，不留悬空态。
            interaction?.cancel()
            interaction = nil
        case .ended:
            let velocity = pan.velocity(in: view).x
            if progress > 0.35 || velocity > 800 {
                // U24：完成关闭时给轻触感（取消时无）。
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                interaction?.finish()
            } else {
                interaction?.cancel()
            }
            interaction = nil
        default:
            break
        }
    }
}

/// slide 进出动画：进从右滑入、出向右滑出（与系统导航 push/pop 同向）。
/// reduced-motion 时时长为 0（瞬间切换，不播位移）。
private final class BearySlideTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool

    init(isPresenting: Bool) {
        self.isPresenting = isPresenting
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return UIAccessibility.isReduceMotionEnabled ? 0 : 0.35
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let toVC = transitionContext.viewController(forKey: .to),
              let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        let container = transitionContext.containerView
        let duration = transitionDuration(using: transitionContext)
        if isPresenting {
            container.addSubview(toView)
            toView.frame = transitionContext.finalFrame(for: toVC)
            let width = container.bounds.width
            toView.transform = CGAffineTransform(translationX: width, y: 0)
            UIView.animate(withDuration: duration, animations: {
                toView.transform = .identity
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        } else {
            container.insertSubview(toView, belowSubview: fromView)
            toView.frame = transitionContext.finalFrame(for: toVC)
            let width = container.bounds.width
            UIView.animate(withDuration: duration, animations: {
                fromView.transform = CGAffineTransform(translationX: width, y: 0)
            }, completion: { _ in
                // 取消时 fromView 由交互式过渡自动复位回原位；完成时视图即将移除，无需清 transform
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}
