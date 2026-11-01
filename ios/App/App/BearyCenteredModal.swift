import UIKit

// ===== 居中 640 编辑器模态（宽 ≥821 的桌面式；对应网页编辑器 ≥821px 居中 640px）=====
// 自定义 presentation：卡片宽 min(640, 容器宽 - 80)、高为 min(内容高, 80% 容器高)、居中；背景黑色 0.45 遮罩。
// 卡片圆角 20、边框 1px line；阴影挂在容器里的独立阴影层上（presentedView 自身裁剪会裁掉自身阴影）。
// 不做背景点击关闭：编辑器取消走自身取消流程（含草稿保留/丢弃），背景点击不得绕过它。
// transitioningDelegate 是弱引用，调用方（SceneDelegate）必须强持有本对象直到 dismiss 完成。
// 部署目标 iOS 15.0——只用闭包回调，不用 async/await。

final class BearyCenteredTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    /// F9：仅邀请弹窗宽屏版置 true——dim 点击关闭；编辑器保持 false（背景点击不得绕过取消流程）。
    var dimTapCloses = false

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        let controller = BearyCenteredPresentationController(presentedViewController: presented, presenting: presenting)
        controller.dimTapCloses = dimTapCloses
        return controller
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
    private let cardShadowView = UIView()
    var dimTapCloses = false

    @objc private func dimTapped() {
        presentedViewController.dismiss(animated: true)
    }

    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let bounds = container.bounds
        let width = min(CGFloat(640), bounds.width - 80)
        let capHeight = bounds.height * 0.80
        let preferredHeight = presentedViewController.preferredContentSize.height
        let height = preferredHeight > 0 ? min(capHeight, preferredHeight) : capHeight
        return CGRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    /// 卡片外框：圆角 12（走 BearySheetChrome）+ 1px line 边框。CALayer borderColor 不跟动态色自动走，
    /// 故每次布局与深浅切换时都按当前 trait 重解一次。
    private func applyCardChrome() {
        guard let presentedView = presentedView else { return }
        presentedView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        presentedView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        presentedView.layer.borderWidth = 1
        presentedView.layer.bearyDynamicBorderColor = BearyColors.line.resolvedColor(with: traitCollection)
        presentedView.clipsToBounds = true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyCardChrome()
        }
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView else { return }
        dimmingView.backgroundColor = BearySheetChrome.scrimColor
        dimmingView.alpha = 0
        dimmingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dimmingView)
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: container.topAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // F9：仅 dimTapCloses 时给 dim 加点击关闭手势（邀请宽屏版；编辑器不动）。
        if dimTapCloses {
            dimmingView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
        }
        // 阴影层挂在容器里、presentedView 下方：presentedView 自身 clipsToBounds 会裁掉
        // 挂它身上的阴影，故阴影不能挂 presentedView。CSS 阴影 0 24 60 黑 30%，
        // CALayer radius 取 CSS blur 一半即 30（与底 sheet 32→16 同口径）。
        cardShadowView.backgroundColor = .clear
        cardShadowView.layer.shadowColor = UIColor.black.cgColor
        cardShadowView.layer.shadowOpacity = 0.30
        cardShadowView.layer.shadowOffset = CGSize(width: 0, height: 24)
        cardShadowView.layer.shadowRadius = 30
        container.addSubview(cardShadowView)
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 1 }, completion: nil)
        } else {
            dimmingView.alpha = 1
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed {
            cardShadowView.removeFromSuperview()
        }
    }

    override func dismissalTransitionWillBegin() {
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 0 }, completion: nil)
        } else {
            dimmingView.alpha = 0
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        if completed {
            cardShadowView.removeFromSuperview()
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        // 旋转/多任务改容器尺寸时重算卡片帧（居中、宽/高上限只跟容器走），
        // 外框与阴影层同步跟帧走。
        guard let presentedView = presentedView else { return }
        let frame = frameOfPresentedViewInContainerView
        presentedView.frame = frame
        applyCardChrome()
        cardShadowView.frame = frame
        cardShadowView.layer.shadowPath = UIBezierPath(roundedRect: cardShadowView.bounds, cornerRadius: BearySheetChrome.topCornerRadius).cgPath
    }
}

/// 淡入 + 小幅上滑：reduced-motion 时时长为 0（瞬间切换，不播透明度与位移）。
/// 呈现初态下偏约 4% 卡片高、淡入至原位；关闭反向（淡出 + 下偏 4% 高）。
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
        let duration = transitionDuration(using: transitionContext)
        if isPresenting {
            guard let toView = transitionContext.view(forKey: .to),
                  let toVC = transitionContext.viewController(forKey: .to) else {
                transitionContext.completeTransition(false)
                return
            }
            container.addSubview(toView)
            let offset = transitionContext.finalFrame(for: toVC).height * 0.04
            toView.alpha = 0
            toView.transform = CGAffineTransform(translationX: 0, y: offset)
            if duration == 0 {
                toView.alpha = 1
                toView.transform = .identity
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
                toView.alpha = 1
                toView.transform = .identity
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        } else {
            guard let fromView = transitionContext.view(forKey: .from) else {
                transitionContext.completeTransition(false)
                return
            }
            let offset = fromView.bounds.height * 0.04
            if duration == 0 {
                fromView.alpha = 0
                fromView.transform = CGAffineTransform(translationX: 0, y: offset)
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            UIView.animate(withDuration: duration, delay: 0, options: .curveEaseIn, animations: {
                fromView.alpha = 0
                fromView.transform = CGAffineTransform(translationX: 0, y: offset)
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}
