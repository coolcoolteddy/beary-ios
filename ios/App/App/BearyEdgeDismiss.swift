import UIKit

// ===== 全屏 modal 的左边缘右滑返回（第三项：原生返回）=====
// 全屏 modal、只能点按钮关闭的页，在这里加上 iOS 原生导航同款手势：
// 从屏幕左边缘右滑 → 视图跟手右移；滑过 35% 宽度或右滑速度够快 → 松手完成关闭；
// 没滑够 → 松手回弹取消。关闭按钮保留。
// 实现：自定义 transitioningDelegate + slide 进出动画（进从右滑入、出向右滑出）+
// UIPercentDrivenInteractiveTransition 驱动交互式关闭。transitioningDelegate 是弱引用，
// 调用方（SceneDelegate）必须强持有本对象直到 dismiss 完成，否则手势中途失效。
// 注意：只接全屏 modal。
// 完成模式（onEdgeSwipeCompleted）：编辑器取消要先存草稿/清临时文件、不能由手势
// 直接 dismiss，故本页不走交互式过渡——边缘滑过阈值后只调回调，由回调走原取消
// 流程（发布在途只 toast、引用面板开着只退面板、其余走存草稿后关页）；没滑够则
// 什么都不做。完成模式下视图不跟手滑走，这是为保草稿有意为之，不是手势失效。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

final class BearyEdgeDismissController: NSObject, UIViewControllerTransitioningDelegate {

    private weak var presentedVC: UIViewController?
    private var interaction: UIPercentDrivenInteractiveTransition?
    private var completionMode = false

    /// 完成模式回调：设置后本控制器不再驱动交互式过渡，只在边缘滑过阈值
    /// （35% 宽度或右滑速度 >800）时调一次回调，关闭由回调方自己的流程完成。
    var onEdgeSwipeCompleted: (() -> Void)?

    /// 交互式退出开始前的统一判断：返回 false 时不启动交互式过渡、不 dismiss，
    /// 调用方自行处理（例如未保存时弹确认，确认后走正常 dismiss 路径）。
    /// 未设置时沿旧口径直接允许；只接需要拦截的页（编辑资料），其余页不设、
    /// 行为不变。关键：判断发生在手势 .began，而不是滑完 .ended 后补确认——
    /// 先拦截，视图才不会在确认前就滑走。
    var shouldAllowInteractiveDismiss: (() -> Bool)?

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
            if let shouldAllow = shouldAllowInteractiveDismiss, !shouldAllow() {
                interaction = nil
                completionMode = false
                return
            }
            if onEdgeSwipeCompleted != nil {
                // 完成模式：不启动交互式过渡，只记下本次手势，阈值在 .ended 判。
                completionMode = true
                interaction = nil
                return
            }
            completionMode = false
            interaction = UIPercentDrivenInteractiveTransition()
            presented.dismiss(animated: true)
        case .changed:
            interaction?.update(progress)
        case .cancelled, .failed:
            // U24：.failed 与 .cancelled 同处理——清理交互式过渡对象，不留悬空态。
            interaction?.cancel()
            interaction = nil
            completionMode = false
        case .ended:
            let velocity = pan.velocity(in: view).x
            if progress > 0.35 || velocity > 800 {
                // U24：完成关闭时给轻触感（取消时无）。
                BearyHaptics.press()
                if completionMode {
                    completionMode = false
                    onEdgeSwipeCompleted?()
                } else {
                    interaction?.finish()
                }
            } else {
                interaction?.cancel()
            }
            interaction = nil
            completionMode = false
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
        return UIAccessibility.isReduceMotionEnabled ? 0 : 0.25
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
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
                toView.transform = .identity
            }, completion: { _ in
                // 117 终态偏离兜底：进场完成时强制归位（此前呈现路径无此复位，
                // 中断时残留位移会留到后续呈现；与退出取消路径的复位同口径）。
                toView.transform = .identity
                toView.frame = transitionContext.finalFrame(for: toVC)
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        } else {
            container.insertSubview(toView, belowSubview: fromView)
            toView.frame = transitionContext.finalFrame(for: toVC)
            let width = container.bounds.width
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseIn, animations: {
                fromView.transform = CGAffineTransform(translationX: width, y: 0)
            }, completion: { _ in
                // 115 设置页空白守卫（根因未证实）：转场取消 / 中断时显式
                // 复位，不依赖交互式过渡的自动复位——若自动复位未发生，
                // 残留的位移 transform 会让整页（含顶栏）停在屏中部。
                // 完成时视图即将移除，复位无副作用。
                if transitionContext.transitionWasCancelled {
                    fromView.transform = .identity
                }
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}
