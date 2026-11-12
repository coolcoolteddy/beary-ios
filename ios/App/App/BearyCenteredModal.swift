import UIKit

// ===== 居中 640 编辑器模态（宽 ≥821 的桌面式；对应网页编辑器 ≥821px 居中 640px）=====
// 自定义 presentation：卡片宽 min(640, 容器宽 - 80)、高为 min(内容高, 80% 容器高)、居中；背景黑色 0.45 遮罩。
// 卡片圆角 20、边框 1px line；阴影挂在容器里的独立阴影层上（presentedView 自身裁剪会裁掉自身阴影）。
// 阴影口径（审计 E2 第 14 项，Li 本轮定夺统一、推翻此前“居中卡片保留自写值”的决定）：
// 居中卡片不再自写 0.30/30/24，统一走轻薄单层 raised token（BearyShadow.applyRaised）。
// 不做背景点击关闭：编辑器取消走自身取消流程（含草稿保留/丢弃），背景点击不得绕过它。
// transitioningDelegate 是弱引用，调用方（SceneDelegate）必须强持有本对象直到 dismiss 完成。
// 部署目标 iOS 15.0——只用闭包回调，不用 async/await。

final class BearyCenteredTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    /// F9：仅邀请弹窗宽屏版置 true——dim 点击关闭；编辑器保持 false（背景点击不得绕过取消流程）。
    var dimTapCloses = false
    /// 审计 2026-11-02 弹窗组：dim 点击的取消路径。置了 handler 时 dim 点击走
    /// handler（调用方一般接被呈现页的 onClose，即走取消路径清理状态），
    /// 而非绕开 onClose 直接 dismiss；未置时回落直接 dismiss（旧行为）。
    var dimTapHandler: (() -> Void)?
    /// 审计 2026-11-02 弹窗组：dismiss 完成回调（取消路径统一清理用，
    /// 如邀请页 dismiss 后清 transitioningDelegate 与强持有）。
    var dismissalHandler: (() -> Void)?

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        let controller = BearyCenteredPresentationController(presentedViewController: presented, presenting: presenting)
        controller.dimTapCloses = dimTapCloses
        controller.dimTapHandler = dimTapHandler
        controller.dismissalHandler = dismissalHandler
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
    /// 审计第 20 项：外层尺寸容器——只负责卡片尺寸与位置，自身永不参与变换。
    /// presentedView（内层）是转场动画位移/透明度的载体；布局回调只写本容器的
    /// frame，内层只写 bounds/center，永不在非 identity transform 下写 frame。
    private let cardFrameView = UIView()
    private var lastShadowBounds: CGRect = .zero
    var dimTapCloses = false
    var dimTapHandler: (() -> Void)?
    var dismissalHandler: (() -> Void)?

    @objc private func dimTapped() {
        // 审计 2026-11-02 弹窗组复核结论：旧 dimTapped 直接 dismiss，确实绕过
        // 被呈现页的 onClose（审计标“未证实”现已证实）；有 handler 时走 handler。
        if let handler = dimTapHandler {
            handler()
        } else {
            presentedViewController.dismiss(animated: BearyMotion.animated(true))
        }
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

    /// 卡片外框：圆角 20，无边框（2026-11-07 微明度定版：分层改明度阶，1px line 边框已去掉）。
    private func applyCardChrome() {
        guard let presentedView = presentedView else { return }
        presentedView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        presentedView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        presentedView.layer.borderWidth = 0
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
        // 挂它身上的阴影，故阴影不能挂 presentedView；阴影在不裁剪的外层、
        // 圆角裁剪由 presentedView 自身负责（见 applyCardChrome）。
        // 审计 E2 第 14 项：统一走轻薄单层 raised token，不再自写数值。
        cardShadowView.backgroundColor = .clear
        BearyShadow.applyRaised(to: cardShadowView.layer)
        container.addSubview(cardShadowView)
        // 审计第 20 项：尺寸容器挂在容器里、阴影层之上；presentedView 随后在
        // 布局回调里被移入本容器（转场动画仍直接作用于 presentedView 本身）。
        cardFrameView.backgroundColor = .clear
        container.addSubview(cardFrameView)
        if let coordinator = presentedViewController.transitionCoordinator {
            coordinator.animate(alongsideTransition: { _ in self.dimmingView.alpha = 1 }, completion: nil)
        } else {
            dimmingView.alpha = 1
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed {
            // 审计 2026-11-02 弹窗组：取消路径同时清遮罩与阴影（旧路径只清阴影）。
            dimmingView.removeFromSuperview()
            cardShadowView.removeFromSuperview()
            cardFrameView.removeFromSuperview()
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
            // 审计 2026-11-02 弹窗组：取消路径同时清遮罩与阴影（旧路径只清阴影），
            // 再通知调用方做 dismiss 后清理（如 transitioningDelegate=nil）。
            dimmingView.removeFromSuperview()
            cardShadowView.removeFromSuperview()
            cardFrameView.removeFromSuperview()
            dismissalHandler?()
        }
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        // 旋转/多任务改容器尺寸时重算卡片帧（居中、宽/高上限只跟容器走），
        // 外框与阴影层同步跟帧走。
        // 审计第 20 项：尺寸只写到不参与变换的外层 cardFrameView；内层
        // presentedView 只写 bounds/center——transform 非 identity 时 frame
        // 无定义，旧代码无条件写 frame 会在转场期间遇旋转/窗口变化时跳变。
        // 转场动画中途把 presentedView 加到容器直属时，这里把它移回外层；
        // transform/alpha 是视图自身属性，移层不影响正在播的动画。
        guard let container = containerView else { return }
        let frame = frameOfPresentedViewInContainerView
        if cardFrameView.superview !== container {
            if cardShadowView.superview === container {
                container.insertSubview(cardFrameView, aboveSubview: cardShadowView)
            } else {
                container.addSubview(cardFrameView)
            }
        }
        cardFrameView.frame = frame
        if let presentedView = presentedView {
            if presentedView.superview !== cardFrameView {
                cardFrameView.addSubview(presentedView)
            }
            // 内层铺满外层：bounds 定尺寸、center 定位置，二者都不受 transform 影响。
            presentedView.bounds = CGRect(origin: .zero, size: frame.size)
            presentedView.center = CGPoint(x: frame.width / 2, y: frame.height / 2)
            applyCardChrome()
        }
        cardShadowView.frame = frame
        // 审计 E2 第 14 项：shadowPath 仅在尺寸变化时更新，不逐帧重算。
        // 冻结令（2026-11-02 Li 新令）：阴影 path 属冻结范围，本支不改计算方式，
        // 原“按实际圆角计算”修法已 revert，见 PR 描述“因冻结未做的样式统一项”。
        if cardShadowView.bounds != lastShadowBounds {
            lastShadowBounds = cardShadowView.bounds
            cardShadowView.layer.shadowPath = UIBezierPath(roundedRect: cardShadowView.bounds, cornerRadius: 20).cgPath
        }
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
        return UIAccessibility.isReduceMotionEnabled ? 0 : BearyMotion.normal
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
