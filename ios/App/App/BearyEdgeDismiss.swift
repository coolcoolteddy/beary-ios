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
// 直接 dismiss，故本页不走交互式过渡。审计 M2（用户亲定改成 1:1 跟手）：
// 开拖先过 shouldAllowCompletionSwipe 预检（发布在途／引用面板开着／已有弹层
// 均不启动跟手）；允许时 .changed 按手指位移 1:1 更新视图 transform；松手滑过
// 阈值后走 onEdgeSwipeCompleted 原取消流程（存草稿后关页）。取舍：草稿保存失败
// 只能在松手走流程时才知道，预检拦不住——松手时取消被拒（拖动中途状态变了，
// 或保存失败），视图滑回原位，不假装已离开。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

final class BearyEdgeDismissController: NSObject, UIViewControllerTransitioningDelegate {

    private weak var presentedVC: UIViewController?
    private var interaction: UIPercentDrivenInteractiveTransition?
    private var completionMode = false

    /// 本次手势是否在 .began 被拒（shouldAllowInteractiveDismiss 或完成模式
    /// 预检）。被拒的手势在 .ended 时直接清理，不触发完成震动、不调完成回调、
    /// 不 finish 交互式过渡（页面实际并未关闭）。
    private var dismissRejected = false

    /// R14 P2-13：提前准备好的返回目标底层画面。全屏 modal 下 presenting
    /// 方的 view 在呈现完成后已不在窗口层级里，旧代码要等正式退场
    /// （animator dismiss 分支）才 insertSubview(toView)，故拖动全程滑开
    /// 的区域背后是空窗口底；拖动开始时即把它插到 presented view 下方，
    /// 目标页全程可见。取消／被拒时在复位动画后撤掉；正式退场时转场容器
    /// 接管它（见 animationController(forDismissed:)），不再碰。
    private var underlyingViewPrepared = false
    private weak var preparedUnderlyingView: UIView?

    /// 完成模式回调：设置后本控制器不再驱动交互式过渡，只在边缘滑过阈值
    /// （35% 宽度或右滑速度 >800）时调一次回调，关闭由回调方自己的流程完成。
    /// 返回值：true 表示退出已在进行（即将关页，或草稿保存已提交、关页随后发生）；
    /// false 表示本次取消被拒（拖动中途状态变了），本控制器把跟手滑走的视图滑回原位。
    var onEdgeSwipeCompleted: (() -> Bool)?

    /// 完成模式开拖前的预检：返回 false 时不启动 1:1 跟手、不 dismiss，
    /// 调用方自行处理（例如发布在途只 toast）。未设置时沿旧口径直接允许。
    /// 判断发生在手势 .began，而不是滑完 .ended 后补确认——先拦截，视图才不会
    /// 在拒绝时已滑走。注意：草稿保存失败只能在松手走原流程时才知道，预检拦不住，
    /// 那条由 onEdgeSwipeCompleted 返回 false 后滑回兜底。
    var shouldAllowCompletionSwipe: (() -> Bool)?

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
        // R14 P2-13：正式退场开始，转场容器接管提前插入的底层画面——
        // animator 的 dismiss 分支会把它 insertSubview 进容器；此处只把
        // 所有权交出去（清旗标），让待撤的延迟清理不再碰它。
        if underlyingViewPrepared {
            underlyingViewPrepared = false
            preparedUnderlyingView = nil
        }
        return BearySlideTransitionAnimator(isPresenting: false)
    }

    func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        return interaction
    }

    // MARK: - R14 P2-13：返回目标底层画面

    /// 拖动开始即把返回目标页提前放进底层：presenting 方的 view 插到
    /// presented view 下方（仅当它当前不在窗口里、且 presented view 未带
    /// 位移时；上一轮复位动画未跑完就又开拖时跳过，本轮按旧口径走）。
    /// 提前插入会触发 presenting 方的 appearance 回调，与正式退场时同一
    /// 套回调（feed 只做本地复位、chrome 的启动 veil 与引导均有已播／已见
    /// 守卫），只是时机从退场提前到开拖，不引入新副作用。
    private func prepareUnderlyingView(for presented: UIViewController) {
        guard let underlying = presented.presentingViewController?.view else { return }
        guard underlying.window == nil, presented.view.transform == .identity else { return }
        guard let superview = presented.view.superview else { return }
        underlying.frame = presented.view.frame
        superview.insertSubview(underlying, belowSubview: presented.view)
        preparedUnderlyingView = underlying
        underlyingViewPrepared = true
    }

    /// 取消／被拒／未过阈值：复位动画跑完后再撤提前插入的底层画面——
    /// 动画期间仍露着它，撤早了复位过程露出的条带会变黑底。
    /// 正式退场已把它接进转场容器时不再碰（见 animationController(forDismissed:)
    /// 的交接；superview 已变的也一律不动，等转场自己收尾）。
    private func removePreparedUnderlyingViewAfterReset() {
        guard underlyingViewPrepared, let underlying = preparedUnderlyingView, let presented = presentedVC else { return }
        // 延迟与复位动画同长（#1000 的 0.30s 弹簧复位）；减动效时复位是瞬时的，延迟取 0。
        let delay = UIAccessibility.isReduceMotionEnabled ? 0 : 0.30
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak underlying, weak presented] in
            guard let self = self, self.underlyingViewPrepared, let underlying = underlying, let presented = presented else { return }
            guard underlying.superview == presented.view.superview, presented.view.window != nil else { return }
            underlying.removeFromSuperview()
            self.underlyingViewPrepared = false
            self.preparedUnderlyingView = nil
        }
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
                dismissRejected = true
                return
            }
            dismissRejected = false
            if onEdgeSwipeCompleted != nil {
                // 完成模式：先过预检门控（发布在途／面板开着／已有弹层），被拒不启动
                // 跟手；允许时只记下本次手势，.changed 按手指 1:1 更新 transform，
                // 阈值在 .ended 判。
                if let shouldAllowCompletion = shouldAllowCompletionSwipe, !shouldAllowCompletion() {
                    completionMode = false
                    interaction = nil
                    dismissRejected = true
                    return
                }
                completionMode = true
                interaction = nil
                // R14 P2-13：拖动开始即准备好返回目标的底层画面，不等正式退场。
                prepareUnderlyingView(for: presented)
                return
            }
            completionMode = false
            interaction = UIPercentDrivenInteractiveTransition()
            presented.dismiss(animated: true)
        case .changed:
            if completionMode {
                // 完成模式 1:1 跟手：视图随手指右移（只向右，不向左出屏）。
                view.transform = CGAffineTransform(translationX: max(pan.translation(in: view).x, 0), y: 0)
            } else {
                interaction?.update(progress)
            }
        case .cancelled, .failed:
            // U24：.failed 与 .cancelled 同处理——清理交互式过渡对象，不留悬空态；
            // 完成模式下视图滑回原位。
            if completionMode {
                resetCompletionFollow(view: view)
                // R14 P2-13：复位后撤提前插入的底层画面（复位曲线本身不动，
                // 本支不碰 resetCompletionFollow——那是 #1000 的范围）。
                removePreparedUnderlyingViewAfterReset()
            } else {
                interaction?.cancel()
            }
            interaction = nil
            completionMode = false
            dismissRejected = false
        case .ended:
            // 被拒的手势直接清理：不震动、不调完成回调、不 finish（页面并未关闭）。
            if dismissRejected {
                dismissRejected = false
                interaction = nil
                completionMode = false
                return
            }
            let velocity = pan.velocity(in: view).x
            if progress > 0.35 || velocity > 800 {
                // U24：完成关闭时给轻触感（取消时无）。
                BearyHaptics.press()
                if completionMode {
                    completionMode = false
                    // 松手确认退出仍走原保存流程；被拒（拖动中途状态变了）时滑回原位。
                    let proceeding = onEdgeSwipeCompleted?() ?? false
                    if !proceeding {
                        // 被拒滑回：松手速度归一化后传弹簧初速度，快甩带 momentum、
                        // 慢拖近 0（与底 sheet／灯箱复位同口径）。
                        resetCompletionFollow(view: view, initialSpringVelocity: BearySheetDrag.restoreSpringVelocity(velocity: velocity, offset: view.transform.tx))
                        // R14 P2-13：被拒滑回后撤提前插入的底层画面。
                        removePreparedUnderlyingViewAfterReset()
                    }
                } else {
                    interaction?.finish()
                }
            } else {
                if completionMode {
                    // 未过阈值滑回：松手速度归一化后传弹簧初速度，快甩带 momentum、
                    // 慢拖近 0（与底 sheet／灯箱复位同口径）。
                    resetCompletionFollow(view: view, initialSpringVelocity: BearySheetDrag.restoreSpringVelocity(velocity: velocity, offset: view.transform.tx))
                    // R14 P2-13：未过阈值滑回后撤提前插入的底层画面。
                    removePreparedUnderlyingViewAfterReset()
                } else {
                    interaction?.cancel()
                }
            }
            interaction = nil
            completionMode = false
            dismissRejected = false
        default:
            break
        }
    }

    /// 完成模式跟手取消／被拒：视图滑回原位（拖拽收尾统一弹簧 0.30s／
    /// damping 0.7，与同文件退场动画同档；快甩松手把手势结束速度归一化后
    /// 传 initialSpringVelocity，慢拖为 0；减动效时瞬时归位）。
    /// 取消／失败无有效松手速度，调用方不传（默认 0）。
    private func resetCompletionFollow(view: UIView, initialSpringVelocity: CGFloat = 0) {
        guard view.transform != .identity else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: initialSpringVelocity, options: [], animations: {
            view.transform = .identity
        })
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
        // 拖拽收尾统一弹簧：退场 0.30s，入场仍 0.25s；减动效门控原已有（时长 0）。
        return UIAccessibility.isReduceMotionEnabled ? 0 : (isPresenting ? 0.25 : 0.30)
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
            // 拖拽收尾统一弹簧 0.30s／damping 0.7：交互式过渡的 animator
            // 实例在手势开始时已建、无松手速度可传，故初速度取 0。
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [], animations: {
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
