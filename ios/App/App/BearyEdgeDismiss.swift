import UIKit

// ===== 全屏 modal 的左边缘右滑返回（第三项：原生返回）=====
// 全屏 modal、只能点按钮关闭的页，在这里加上 iOS 原生导航同款手势：
// 从屏幕左边缘右滑 → 视图跟手右移；滑过 35% 宽度或右滑速度够快 → 松手完成关闭；
// 没滑够 → 松手回弹取消。关闭按钮保留。
// 实现：自定义 transitioningDelegate + slide 进出动画（进从右滑入、出向右滑出）。
// 手势 1:1 直驱：.changed 直接按手指位移改视图 transform，不再走
// UIPercentDrivenInteractiveTransition（弹簧曲线前快后慢，手指 20% 时页面
// 已跑 35%，比手快）；松手滑过阈值再走正常 dismiss，退场弹簧动画接管。
// transitioningDelegate 是弱引用，调用方（SceneDelegate）必须强持有本对象
// 直到 dismiss 完成，否则手势中途失效。
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

    /// 底层画面准备的代次：每次 prepareUnderlyingView 认领／插入时 +1。
    /// removePreparedUnderlyingViewAfterReset 的延迟清理只认领它调度时
    /// 那一代；新一拖已认领底层画面时，旧清理不再碰它。
    private var underlyingGeneration = 0

    /// 详情展开过渡的源行提供者：返回当前真正在屏上的源行视图（卡片行／通知行），
    /// 动画器在开场与关场时各问一次、现量现用（关场重量的即关闭终点）。
    /// 未设置时详情走旧 slide 进出（编辑器等其他全屏 modal 不设、不受影响）；
    /// 返回 nil（源行已滚出视野／不在当前页）时动画器走淡入淡出兜底。
    var expandSourceProvider: (() -> UIView?)?

    /// 完成模式回调：设置后本控制器不再驱动交互式过渡，只在边缘滑过阈值
    /// （35% 宽度或右滑速度 >800）时调一次回调，关闭由回调方自己的流程完成。
    /// 返回值：true 表示退出已在进行（即将关页，或草稿保存已提交、关页随后发生）；
    /// false 表示本次取消被拒（拖动中途状态变了），本控制器把跟手滑走的视图滑回原位。
    var onEdgeSwipeCompleted: (() -> Bool)?

    /// 详情只读返回：来源列表第一次被露出前预恢复锚点（不消费上下文）——
    /// 边缘拖动 .began 插底层画面时、正式退场动画起播前各调一次；只把来源
    /// 列表放回打开时的视口位置，正式的消费型恢复仍由 viewDidDisappear 的
    /// onDismissed 走（已在原位时 ±1pt 守卫直接不动，不产生二次跳变）。
    /// 未设置时（编辑器／私信等其他页）什么都不做。
    var onSourceViewWillReveal: (() -> Void)?

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
        // 详情展开过渡：设了源行提供者时走快照 morph（无源行时动画器内部
        // 回落 slide，不改既有行为）；其余 modal 沿用 slide。
        if expandSourceProvider != nil {
            return BearyDetailExpandAnimator(isPresenting: true, sourceProvider: expandSourceProvider)
        }
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
        // 详情展开过渡：设了源行提供者时走缩回 morph；右滑跟手退场（视图已被
        // 手势拖离原位）与无源行时动画器内部回落 slide／淡出。
        if expandSourceProvider != nil {
            return BearyDetailExpandAnimator(isPresenting: false, sourceProvider: expandSourceProvider)
        }
        return BearySlideTransitionAnimator(isPresenting: false, onDismissWillStart: onSourceViewWillReveal)
    }

    func interactionControllerForDismissal(using animator: UIViewControllerAnimatedTransitioning) -> UIViewControllerInteractiveTransitioning? {
        return interaction
    }

    // MARK: - R14 P2-13：返回目标底层画面

    /// 拖动开始即把返回目标页提前放进底层：presenting 方的 view 插到
    /// presented view 下方。上一轮复位弹簧未跑完就又开拖时（0.26s 窗口内）：
    /// 底层画面若还在（延迟清理未到），直接认领、不重复插，代次往前推，
    /// 让旧的延迟清理失效——否则旧清理会在新拖进行中把底层画面撤掉，
    /// 拖动露窗口底；若已撤掉，先把视图归位再插（新一拖取代未跑完的
    /// 复位弹簧），不再按旧口径跳过。
    /// 提前插入会触发 presenting 方的 appearance 回调，与正式退场时同一
    /// 套回调（feed 只做本地复位、chrome 的启动 veil 与引导均有已播／已见
    /// 守卫），只是时机从退场提前到开拖，不引入新副作用。
    private func prepareUnderlyingView(for presented: UIViewController) {
        guard let underlying = presented.presentingViewController?.view else { return }
        guard let superview = presented.view.superview else { return }
        // 上一轮的底层画面还在：直接认领，不重复插。
        if underlying.window != nil, underlying.superview == superview {
            preparedUnderlyingView = underlying
            underlyingViewPrepared = true
            underlyingGeneration += 1
            // 已在上一拖露出过、预恢复已做过；再调一次无害（不消费上下文，
            // 已在原位时 ±1pt 守卫直接不动）。
            onSourceViewWillReveal?()
            return
        }
        // 底层画面已在别处（正走退场转场、已被容器接管）时不动它。
        guard underlying.window == nil else { return }
        // 新一拖取代未跑完的复位弹簧：先把视图归位再插。
        if presented.view.transform != .identity {
            presented.view.transform = .identity
        }
        underlying.frame = presented.view.frame
        superview.insertSubview(underlying, belowSubview: presented.view)
        preparedUnderlyingView = underlying
        underlyingViewPrepared = true
        underlyingGeneration += 1
        // 来源页刚被插进层级、手指尚未拖出第一帧：先把来源列表放回打开时
        // 的视口位置，再让用户看到它（同步在 .began 主线程内做完，下一帧
        // 渲染时位置已是对的；不消费上下文，正式恢复仍走 viewDidDisappear）。
        onSourceViewWillReveal?()
    }

    /// 取消／被拒／未过阈值：复位动画跑完后再撤提前插入的底层画面——
    /// 动画期间仍露着它，撤早了复位过程露出的条带会变黑底。
    /// 正式退场已把它接进转场容器时不再碰（见 animationController(forDismissed:)
    /// 的交接；superview 已变的也一律不动，等转场自己收尾）。
    private func removePreparedUnderlyingViewAfterReset() {
        guard underlyingViewPrepared, let underlying = preparedUnderlyingView, let presented = presentedVC else { return }
        // 延迟与复位动画同长（#1000 的 motion.normal 0.26s 弹簧复位）；减动效时复位是瞬时的，延迟取 0。
        let delay = UIAccessibility.isReduceMotionEnabled ? 0 : BearyMotion.normal
        // 只认领调度时那一代：新一拖已认领底层画面时，旧清理不再碰它。
        let generation = underlyingGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak underlying, weak presented] in
            guard let self = self, self.underlyingViewPrepared, self.underlyingGeneration == generation, let underlying = underlying, let presented = presented else { return }
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
        // 130 扫 bug：translation/velocity 必须在不动的坐标系里量。
        // 之前取在被拖动的 view 自身坐标系里：view 一右移，它的坐标系跟着走，
        // 量到的位移只有手指位移的一半（页面比手慢一半、35% 阈值实际要拖 70% 宽、
        // 800pt/s 甩速实际要 1600pt/s）。底 sheet 同款量在 container 里。
        // 呈现容器的 superview 是不动的，取它；取不到时退回 view（旧口径）。
        let referenceView = view.superview ?? view
        let progress = min(max(pan.translation(in: referenceView).x / width, 0), 1)
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
            interaction = nil
            // 1:1 跟手改版：不再启动交互式过渡（弹簧曲线会让页面比手快）；
            // R14 P2-13：拖动开始即准备好返回目标的底层画面，不等正式退场。
            // .changed 直接按手指位移改视图 transform，松手过阈值再走正常 dismiss。
            prepareUnderlyingView(for: presented)
        case .changed:
            // 被拒的手势不跟手：.began 里 return 并不会停掉 recognizer，手指
            // 继续滑仍会送 .changed；不拦这里，被拒的手势（引用面板开着）
            // 照样把视图拖走，松手又在 dismissRejected 分支直接 return，
            // 视图就冻在半偏移位。见 .ended 的 dismissRejected 分支。
            guard !dismissRejected else { return }
            // 1:1 跟手：视图随手指右移（只向右，不向左出屏）。完成模式与普通模式同款。
            // 位移取在不动的 referenceView 坐标系里（见 handler 顶部注释），
            // 取在被拖动的 view 自身坐标系里只有一半。
            view.transform = CGAffineTransform(translationX: max(pan.translation(in: referenceView).x, 0), y: 0)
        case .cancelled, .failed:
            // U24：.failed 与 .cancelled 同处理——视图滑回原位＋撤底层画面，不留悬空态。
            resetCompletionFollow(view: view)
            // R14 P2-13：复位后撤提前插入的底层画面（复位曲线本身不动，
            // 本支不碰 resetCompletionFollow——那是 #1000 的范围）。
            removePreparedUnderlyingViewAfterReset()
            interaction = nil
            completionMode = false
            dismissRejected = false
        case .ended:
            // 被拒的手势直接清理：不震动、不调完成回调、不 finish（页面并未关闭）。
            // 兜底复位：视图绝不能停在半偏移位——.changed 即使被拦，也可能带
            // 残留位移（上一轮复位动画未跑完又开拖）；任何未真正 dismiss 的
            // 手势结束都必须把视图滑回原位，不能只靠某一条复位路径。
            if dismissRejected {
                resetCompletionFollow(view: view)
                dismissRejected = false
                interaction = nil
                completionMode = false
                return
            }
            let velocity = pan.velocity(in: referenceView).x
            if progress > 0.35 || velocity > 800 {
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
                    // 1:1 跟手改版：松手过阈值走正常 dismiss，退场弹簧动画从手指
                    // 停下的位置接管；提前插入的底层画面按 R14 交接口径由 animator 接管。
                    presented.dismiss(animated: true)
                }
            } else {
                // 未过阈值滑回：松手速度归一化后传弹簧初速度，快甩带 momentum、
                // 慢拖近 0（与底 sheet／灯箱复位同口径）。
                resetCompletionFollow(view: view, initialSpringVelocity: BearySheetDrag.restoreSpringVelocity(velocity: velocity, offset: view.transform.tx))
                // R14 P2-13：未过阈值滑回后撤提前插入的底层画面。
                removePreparedUnderlyingViewAfterReset()
            }
            interaction = nil
            completionMode = false
            dismissRejected = false
        default:
            break
        }
    }

    /// 完成模式跟手取消／被拒：视图滑回原位（拖拽收尾统一弹簧 0.26s／
    /// damping 0.7，与同文件退场动画同档；快甩松手把手势结束速度归一化后
    /// 传 initialSpringVelocity，慢拖为 0；减动效时瞬时归位）。
    /// 取消／失败无有效松手速度，调用方不传（默认 0）。
    private func resetCompletionFollow(view: UIView, initialSpringVelocity: CGFloat = 0) {
        guard view.transform != .identity else { return }
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : BearyMotion.normal, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: initialSpringVelocity, options: [], animations: {
            view.transform = .identity
        })
    }
}

/// slide 进出动画：进从右滑入、出向右滑出（与系统导航 push/pop 同向）。
/// reduced-motion 时时长为 0（瞬间切换，不播位移）。
private final class BearySlideTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool
    /// 正式退场起播前调一次（来源页刚被插进容器、尚未露出一帧时）；
    /// 其余页不设，行为不变。
    private let onDismissWillStart: (() -> Void)?

    init(isPresenting: Bool, onDismissWillStart: (() -> Void)? = nil) {
        self.isPresenting = isPresenting
        self.onDismissWillStart = onDismissWillStart
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        // 入场／退场均走 motion.normal 0.26s（第十轮三档收敛，原入场 0.25s／退场 0.30s）；减动效门控原已有（时长 0）。
        return UIAccessibility.isReduceMotionEnabled ? 0 : BearyMotion.normal
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
            // 详情只读返回：退场动画起播前先把来源列表放回打开时的视口位置——
            // 此时来源页刚被插进容器、尚未露出一帧；等 viewDidDisappear 再恢复
            // 会在动画结束时改 contentOffset，产生一次跳变。本回调只预恢复、
            // 不消费上下文，正式恢复仍走 viewDidDisappear 的 onDismissed。
            onDismissWillStart?()
            let width = container.bounds.width
            // 拖拽收尾统一弹簧 0.26s／damping 0.7：交互式过渡的 animator
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

/// 日记详情展开过渡（2026-11-18 Li 定，预览 Space ri-ji-xiang-qing-zhan-kai-guo-du-yu-lan）：
/// 点卡片／通知行打开详情时，详情从源行的精确位置／大小／圆角连续长成整页；
/// 返回时沿原路平滑缩回源行。背景列表只变暗（标准 scrim），不缩放、不缩小。
///
/// 手感与灯箱进场缩放同档：0.26s（BearyMotion.normal）、临界阻尼弹簧 1.0，
/// 无超调（灯箱关场阻尼 2026-11-17 #1544 定，0.7 欠阻尼超调约 4.6% 会闪高）。
/// #1987 灯箱开场缩放支尚未合入 main，本动画器按同一口径独立实现，
/// 未复用其类；两支都合入后可视情况归一。
///
/// 防闪：开场先把详情按终态铺好（layoutIfNeeded）、快照落在源行矩形上再开
/// 动画，首帧即完整画面，中间不露窗口黑底（灯箱 ReturnAnimator 同款思路，
/// 关场第一步先把底层页加进容器）。
/// 兜底：减动效时只淡入淡出、不动位置；开场无源行（深链／搜索／引用）沿用旧
/// slide 入场；关场源行已滚出视野／无源行时淡出；右滑跟手退场（视图已被手势
/// 拖离原位）走旧 slide 退场，与拖动连续。详情页自身内容、卡片布局、
/// 通知逻辑一字不动，只改过渡。
final class BearyDetailExpandAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool
    private let sourceProvider: (() -> UIView?)?

    init(isPresenting: Bool, sourceProvider: (() -> UIView?)?) {
        self.isPresenting = isPresenting
        self.sourceProvider = sourceProvider
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return BearyMotion.normal
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        if isPresenting {
            animatePresent(using: transitionContext)
        } else {
            animateDismiss(using: transitionContext)
        }
    }

    // MARK: - 源行矩形

    /// 源行在转场容器里的矩形；行必须真正在屏上才算——任一祖先隐藏／透明、
    /// 不在窗口里、或矩形不完整落在容器内时返回 nil（调用方走兜底）。
    /// 隐藏页里的行（cellForRow 仍取得到）由祖先 isHidden 拦住，不会误认。
    private func sourceRectInContainer(_ sourceView: UIView, container: UIView) -> CGRect? {
        var ancestor: UIView? = sourceView
        while let view = ancestor {
            if view.isHidden || view.alpha == 0 { return nil }
            ancestor = view.superview
        }
        guard sourceView.window != nil else { return nil }
        let rect = container.convert(sourceView.convert(sourceView.bounds, to: nil), from: nil)
        guard container.bounds.insetBy(dx: -1, dy: -1).contains(rect) else { return nil }
        return rect
    }

    // MARK: - 开场

    private func animatePresent(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        let duration = transitionDuration(using: transitionContext)
        guard let toVC = transitionContext.viewController(forKey: .to),
              let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        let finalFrame = transitionContext.finalFrame(for: toVC)
        container.addSubview(toView)
        toView.frame = finalFrame
        // 首帧提交：详情先按终态排好版，再开动画，中间不闪。
        toView.layoutIfNeeded()
        toView.alpha = 0
        // 减动效：只淡入，不动位置。
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: duration, animations: {
                toView.alpha = 1
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
            return
        }
        guard let provider = sourceProvider,
              let sourceView = provider(),
              let sourceRect = sourceRectInContainer(sourceView, container: container),
              sourceRect.width > 0, sourceRect.height > 0,
              let snapshot = sourceView.snapshotView(afterScreenUpdates: false) else {
            // 无源行（深链／搜索／引用）或快照失败：沿用旧 slide 入场，
            // 不改既有行为；toView 已就位，直接淡入亦可，此处交回 slide。
            toView.alpha = 1
            BearySlideTransitionAnimator(isPresenting: true).animateTransition(using: transitionContext)
            return
        }
        // 背景列表只变暗（标准 scrim），不缩放。
        let dimView = UIView(frame: container.bounds)
        dimView.backgroundColor = BearySheetChrome.scrimColor
        dimView.alpha = 0
        container.insertSubview(dimView, belowSubview: toView)
        // 2026-11-22 拉长修复：快照不再直接改帧——位图随帧非等比拉伸
        // （宽约 1.09 倍、高约 4 倍）就是 Li 报的“卡片被拉长”。改为裁剪窗
        // + 等比缩放：clipView 带圆角裁剪、帧从源行矩形长到整页；快照钉
        // 在裁剪窗左上角、只做等比缩放（宽比 = 终宽 / 源宽），内容全程
        // 不变形；裁剪窗长出的区域由下方渐显的真详情页填满，快照在末段
        // 淡出、与真页溶解交接。
        let radius = sourceView.layer.cornerRadius
        let clipView = UIView(frame: sourceRect)
        clipView.clipsToBounds = true
        clipView.layer.cornerRadius = radius
        snapshot.frame = CGRect(origin: .zero, size: sourceRect.size)
        snapshot.layer.anchorPoint = CGPoint(x: 0, y: 0)
        snapshot.layer.position = .zero
        clipView.addSubview(snapshot)
        container.addSubview(clipView)
        container.layoutIfNeeded()
        let scale = finalFrame.width / sourceRect.width
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0, options: .curveEaseOut, animations: {
            clipView.frame = finalFrame
            clipView.layer.cornerRadius = 0
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            dimView.alpha = 1
        }, completion: { _ in
            // 弹簧临界阻尼单调趋近目标，结束时帧即终态；先显式归位再换真页，
            // 快照与真页同一帧交接，不跳变。
            clipView.frame = finalFrame
            toView.alpha = 1
            snapshot.removeFromSuperview()
            clipView.removeFromSuperview()
            dimView.removeFromSuperview()
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
        // 真详情页随裁剪窗长大渐显（填满快照下方的空区）；快照在末段淡出，
        // 与真页溶解交接，不留硬切。
        UIView.animate(withDuration: duration * 0.7, delay: 0, options: .curveEaseOut, animations: {
            toView.alpha = 1
        })
        UIView.animate(withDuration: duration * 0.35, delay: duration * 0.65, options: .curveEaseOut, animations: {
            snapshot.alpha = 0
        })
    }

    // MARK: - 关场

    private func animateDismiss(using transitionContext: UIViewControllerContextTransitioning) {
        let container = transitionContext.containerView
        let duration = transitionDuration(using: transitionContext)
        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to),
              let toVC = transitionContext.viewController(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        // 底层页先就位（ReturnAnimator 同款防闪），再做一切动画。
        toView.frame = transitionContext.finalFrame(for: toVC)
        container.addSubview(toView)
        container.addSubview(fromView)
        // 右滑跟手退场：视图已被手势拖离原位，走旧 slide 退场，与拖动连续。
        if fromView.transform != .identity {
            BearySlideTransitionAnimator(isPresenting: false).animateTransition(using: transitionContext)
            return
        }
        // 减动效：只淡出，不动位置。
        if UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: duration, animations: {
                fromView.alpha = 0
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
            return
        }
        // 关场重量的源行位置即关闭终点；源行已滚出视野／无源行／快照失败时淡出。
        guard let provider = sourceProvider,
              let sourceView = provider(),
              let targetRect = sourceRectInContainer(sourceView, container: container),
              targetRect.width > 0, container.bounds.width > 0,
              let snapshot = fromView.snapshotView(afterScreenUpdates: false) else {
            UIView.animate(withDuration: duration, animations: {
                fromView.alpha = 0
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
            return
        }
        let radius = sourceView.layer.cornerRadius
        // 开场结束时列表是 dim 态：关场先以同等 dim 盖住列表，再随快照缩小淡回。
        let dimView = UIView(frame: container.bounds)
        dimView.backgroundColor = BearySheetChrome.scrimColor
        dimView.alpha = 1
        container.insertSubview(dimView, aboveSubview: toView)
        // 2026-11-22 拉长修复：同开场，快照不再直接改帧压进卡片矩形
        // （整页位图被纵向压扁）；改为裁剪窗 + 等比缩放：裁剪窗从整页
        // 收到卡片矩形，快照钉左上角、等比缩到卡片宽，内容全程不变形；
        // 快照在末段淡出，露出下方已回到原位的真卡片。
        let clipView = UIView(frame: container.bounds)
        clipView.clipsToBounds = true
        clipView.layer.cornerRadius = 0
        snapshot.frame = container.bounds
        snapshot.layer.anchorPoint = CGPoint(x: 0, y: 0)
        snapshot.layer.position = .zero
        clipView.addSubview(snapshot)
        container.addSubview(clipView)
        fromView.alpha = 0
        container.layoutIfNeeded()
        let scale = targetRect.width / container.bounds.width
        UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: 1.0, initialSpringVelocity: 0, options: .curveEaseOut, animations: {
            clipView.frame = targetRect
            clipView.layer.cornerRadius = radius
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            dimView.alpha = 0
        }, completion: { _ in
            clipView.frame = targetRect
            snapshot.removeFromSuperview()
            clipView.removeFromSuperview()
            dimView.removeFromSuperview()
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
        // 快照在末段淡出，露出下方已回到原位的真卡片，不留硬切。
        UIView.animate(withDuration: duration * 0.35, delay: duration * 0.65, options: .curveEaseOut, animations: {
            snapshot.alpha = 0
        })
    }
}

// MARK: - 全屏 nav modal 共享入口（第二十四批第 6 项）

// 七处「全屏 nav modal」同一副骨架收一处：nav 包裹＋藏栏＋全屏＋
// EdgeDismiss（attach＋transitioningDelegate）＋present。调用方须把返回的
// edgeDismiss 存进强持有属性（transitioningDelegate 弱引用，不持有则手势与
// 动画代理失效）；nav 由调用方按需取用（如标签页的 onBack／shouldAllow 门）。
// hidesNavigationBar 默认 true；Profile 地图／星图两处原就不藏栏，传 false，
// 此时连赋值都不做（isNavigationBarHidden 默认即 false），行为与原来逐字一致。
@discardableResult
func presentFullscreenNav(
    root: UIViewController,
    from presenter: UIViewController,
    hidesNavigationBar: Bool = true,
    configureEdgeDismiss: ((BearyEdgeDismissController, UINavigationController) -> Void)? = nil
) -> (nav: UINavigationController, edgeDismiss: BearyEdgeDismissController) {
    let nav = UINavigationController(rootViewController: root)
    if hidesNavigationBar {
        nav.isNavigationBarHidden = true
    }
    nav.modalPresentationStyle = .fullScreen
    let edgeDismiss = BearyEdgeDismissController()
    configureEdgeDismiss?(edgeDismiss, nav)
    edgeDismiss.attach(to: nav)
    nav.transitioningDelegate = edgeDismiss
    presenter.present(nav, animated: BearyMotion.animated(true))
    return (nav, edgeDismiss)
}
