import UIKit

// ===== 居中 640 编辑器模态（宽 ≥821 的桌面式；对应网页编辑器 ≥821px 居中 640px）=====
// 自定义 presentation：卡片宽 min(640, 容器宽 - 32)、高为容器高的 88%、居中；背景黑色 0.45 遮罩。
// 不做背景点击关闭：编辑器取消走自身取消流程（含草稿保留/丢弃），背景点击不得绕过它。
// transitioningDelegate 是弱引用，调用方（SceneDelegate）必须强持有本对象直到 dismiss 完成，
// 与 edgeDismiss 同口径。部署目标 iOS 15.0——只用闭包回调，不用 async/await。

final class BearyCenteredTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        return BearyCenteredPresentationController(presentedViewController: presented, presenting: presenting)
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyCenteredFadeAnimator(isPresenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        return BearyCenteredFadeAnimator(isPresenting: false)
    }
}

private final class BearyCenteredPresentationController: UIPresentationController {

    private let dimmingView = UIView()

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let bounds = container.bounds
        let width = min(CGFloat(640), bounds.width - 32)
        let height = bounds.height * 0.88
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView else { return }
        dimmingView.backgroundColor = UIColor(white: 0, alpha: 0.45)
        dimmingView.alpha = 0
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dimmingView)
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: container.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 1 }, completion: nil)
        } else {
            dimmingView.alpha = 1
        }
    }

    override func dismissalTransitionWillBegin() {
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 0 }, completion: nil)
        } else {
            dimmingView.alpha = 0
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        // 旋转/多任务改容器尺寸时重算卡片位置（居中 640 不变，只跟容器走）
        presentedView?.frame = frameOfPresentedViewInContainerView
    }
}

/// 淡入淡出：reduced-motion 时时长为 0（瞬间切换，不播透明度）。
private final class BearyCenteredFadeAnimator: NSObject, UIViewControllerAnimatedTransitioning {

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
        if isPresenting {
            guard let toView = transitionContext.view(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            container.addSubview(toView)
            toView.alpha = 0
            UIView.animate(withDuration: transitionDuration(using: transitionContext), animations: {
                toView.alpha = 1
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            UIView.animate(withDuration: transitionDuration(using: transitionContext), animations: {
                fromView.alpha = 0
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}
