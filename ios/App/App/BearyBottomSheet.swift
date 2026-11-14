import UIKit

// ===== 共享底部弹窗容器（Li 2026-11-05 新令：所有弹窗改底部弹窗）=====
// 用法：任何弹窗 VC 设 modalPresentationStyle = .custom，transitioningDelegate =
// BearyBottomSheetTransitioningDelegate()（或传 presentationControllerFactory
// 供自定义子类，如登录弹窗的 chrome + 键盘逻辑）；容器负责其余全部：
// 出现——弹窗弹簧 0.38s / damping 0.7 从底部升起，背后页面同步缩 0.92 倍、
// 圆角 16pt、黑色遮罩压暗 0.45；拖动——弹窗可上下拖，下滑 1:1 跟手、上滑
// 按 0.3 阻力折算，松手下拖超 80pt 或下甩速度 > 600pt/s 关闭、否则弹簧
// （0.26s / damping 0.7）弹回；关闭——背后页面同步恢复。遮罩点按与拖动关闭都走 requestDismiss
//（子类可重写，如登录弹窗改走 cancelFromSheet——先停倒计时与在途任务，
// 容器不得绕开它直接 dismiss，否则添加账号会话守卫 stays armed）。
// 减动效开时：出现/关闭瞬时、拖动关闭无动画直接关、背后页面瞬时恢复。
// VoiceOver（r29-14）：出现前记 sheet 外焦点、置 presentedView isModal、出现完成
// 聚焦首元素（BearyBottomSheetVoiceOver 钩子，默认 nil）、关闭完成还焦点、
// 拖动取消焦点回 sheet 内；范式见 BearyEmotePickerSheet / BearyDraftBoxViewController /
// BearyNotificationsViewController，真机仍需验 containment 是否如预期。
// 右上角叉叉关闭由各弹窗自己保留，容器不管叉叉按钮本身。
// 本文件只含容器；各弹窗的 chrome（玻璃/抓手/阴影）与内容逻辑留在各自文件。
// 迁移范围：先登录弹窗当样板（见 BearyLoginSheet.swift），其余弹窗等 Li 看过
// 样板后再分批迁移，不要一次全改。

enum BearyBottomSheet {
    /// 背后页面缩小倍数（出现时 1 → 0.92）。
    static let backgroundScale: CGFloat = 0.92
    /// 背后页面圆角（出现时原值 → 16pt）。
    static let backgroundCornerRadius: CGFloat = 16
    /// 遮罩压暗（黑色，出现时 0 → 0.45，与 BearySheetChrome.scrimAlpha 同值）。
    static let dimAlpha: CGFloat = 0.45
    /// 出现/关闭弹簧时长（present/dismiss 用，走 motion.screen 0.38s）。
    static let springDuration: TimeInterval = BearyMotion.screen
    /// 出现/关闭弹簧阻尼（present/dismiss 用，走 motion.springDamping 0.7）。
    static let springDamping: CGFloat = BearyMotion.springDamping
    /// 拖拽收尾弹簧时长（规范 §6：拖拽收尾统一 0.26s，restoreDrag 用）。
    static let dragSpringDuration: TimeInterval = BearyMotion.normal
    /// 拖拽收尾弹簧阻尼（规范 §6：拖拽收尾统一 damping 0.7，restoreDrag 用）。
    static let dragSpringDamping: CGFloat = 0.7
    /// 下拖关闭位移阈值（规范 §6：拖动关闭统一位移 ＞80pt）。
    static let dismissDistance: CGFloat = 80
    /// 下拖关闭速度阈值（规范 §6：拖动关闭统一速度 ＞600pt/s）。
    static let dismissVelocity: CGFloat = 600
    /// 上拖阻力系数（超出静止位置的部分按 0.25 折算，与 BearySheetDrag 同口径）。
    static let upwardResistance: CGFloat = 0.25
}

// MARK: - VoiceOver 焦点钩子（r29-14）

/// 底部弹窗出现时 VoiceOver 首焦点元素：presented VC 可 conform 提供；
/// 默认 nil（协议扩展）——未提供的 sheet 出现时不另发焦点，只声明模态。
/// 按仓内先例（EmotePicker/DraftBox/Notifications）首选标题；
/// 登录 sheet 已接线：BearyLoginViewController 返回 sheet 专属标题 welcomeTitleLabel。
protocol BearyBottomSheetVoiceOver {
    var bottomSheetInitialAccessibilityElement: AnyObject? { get }
}

extension BearyBottomSheetVoiceOver {
    var bottomSheetInitialAccessibilityElement: AnyObject? { nil }
}

// MARK: - Transitioning delegate

final class BearyBottomSheetTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {

    typealias PresentationControllerFactory = (_ presented: UIViewController, _ presenting: UIViewController?, _ source: UIViewController) -> BearyBottomSheetPresentationController

    private let factory: PresentationControllerFactory
    private weak var sheetPresentationController: BearyBottomSheetPresentationController?

    init(presentationControllerFactory: PresentationControllerFactory? = nil) {
        self.factory = presentationControllerFactory ?? { presented, presenting, _ in
            BearyBottomSheetPresentationController(presentedViewController: presented, presenting: presenting)
        }
        super.init()
    }

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        let pc = factory(presented, presenting, source)
        sheetPresentationController = pc
        return pc
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BearyBottomSheetAnimator(isPresenting: true, presentationController: sheetPresentationController)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BearyBottomSheetAnimator(isPresenting: false, presentationController: sheetPresentationController)
    }
}

// MARK: - Presentation controller

class BearyBottomSheetPresentationController: UIPresentationController {

    private let dimView = UIView()
    private var dragPan: UIPanGestureRecognizer?
    /// 挂在 presentedView 之外的拖动手势（如登录弹窗顶部 chrome 条上的那只），
    /// 与 dragPan 同 target/action、同仲裁；见 installExtraDragPan。
    private var extraDragPans: [UIPanGestureRecognizer] = []
    private var backgroundOriginalTransform: CGAffineTransform = .identity
    private var backgroundOriginalCornerRadius: CGFloat = 0
    private var backgroundOriginalMasksToBounds = false
    /// 拖动关闭时记下的松手速度（供退场弹簧初速度，animator 读；读完即清）。
    var dismissVelocity: CGFloat = 0
    /// VoiceOver 焦点返回：presentationTransitionWillBegin 时记下 sheet 外当前焦点元素
    ///（EmotePicker :97–101 / Notifications :2740–2746 同款写法：weak 持有，
    /// iOS 17 起取焦点 API 作守门；旧系统无显式返回、走系统默认行为）。
    private weak var previousFocusedElement: AnyObject?
    /// 本次拖动起手时触点命中的滚动视图（.began 时记下；无滚动内容时为 nil）：
    /// 一次手势内只认这一只，避免中途换滚动视图导致抖动。
    private weak var dragScrollView: UIScrollView?
    /// 本次拖动弹窗接手的位移原点（手势累计位移，容器坐标）：接手前内容先滚、
    /// 弹窗不动；滚到头才接手，接手后弹窗位移按（当前位移 − 原点）折算，
    /// 接手瞬间位移为 0、不跳变。nil = 本次手势尚未接手（内容在滚）。
    private var dragTakeoverTranslation: CGFloat?
    /// 接手时手指方向（+1 下拉、−1 上拉）：手指回到接手点并反向越过、
    /// 且内容能往新方向滚时，把手势交还内容。
    private var dragTakeoverSign: CGFloat = 1
    /// 本次拖动实际作用到弹窗上的位移（最后一次传给 applySheetTransform 的 ty）：
    /// 松手关／回弹按它裁决，不按手势原始位移（原始位移含内容滚动那段）。
    private var appliedDragOffset: CGFloat = 0

    /// 关闭请求：默认直接 dismiss；子类重写改走自己的关闭路径
    ///（如登录弹窗的 cancelFromSheet——先停倒计时与在途任务）。
    func requestDismiss() {
        presentedViewController.dismiss(animated: true)
    }

    /// 拖动/弹回时弹窗本体的 transform：子类重写时先调 super 再同步
    /// 自己的 chrome（玻璃/抓手/阴影），保证与内容同一 transform。
    /// 注意：进退场动画不走本方法，chrome 由 setSheetPresented 驱动（见下）。
    func applySheetTransform(_ transform: CGAffineTransform) {
        presentedView?.transform = transform
    }

    /// 出现/关闭终态（只赋值、不自带动效，调用方须在动画块内调，
    /// 否则直落终值无过渡；减动效路径直接调本方法即终态）。
    /// presented=true：遮罩 0.45、背后缩 0.92、圆角 16；
    /// presented=false：遮罩 0、背后恢复原样。
    /// 子类重写时先调 super 再同步自己的 chrome 终态。
    func setSheetPresented(_ presented: Bool) {
        applyPresentationProgress(presented ? 0 : 1)
    }

    /// 出现进度 0（完全出现）→ 1（完全关闭）对应的遮罩与背后页面状态；
    /// 拖动时按位移比例调，出现/关闭动画调两端。
    /// 本方法不走虚方法表：transitionWillBegin/DidEnd 的非动画路径调它，
    /// 避免子类 chrome 在未摆好前被虚调用提前置终态（见登录弹窗注释）。
    func applyPresentationProgress(_ progress: CGFloat) {
        let p = max(0, min(1, progress))
        dimView.alpha = BearyBottomSheet.dimAlpha * (1 - p)
        guard let backgroundView = presentingViewController.view else { return }
        if p >= 1 {
            backgroundView.transform = backgroundOriginalTransform
            backgroundView.layer.cornerRadius = backgroundOriginalCornerRadius
            backgroundView.layer.masksToBounds = backgroundOriginalMasksToBounds
        } else {
            let scale = 1 - (1 - BearyBottomSheet.backgroundScale) * (1 - p)
            backgroundView.transform = backgroundOriginalTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
            backgroundView.layer.cornerRadius = backgroundOriginalCornerRadius + (BearyBottomSheet.backgroundCornerRadius - backgroundOriginalCornerRadius) * (1 - p)
            backgroundView.layer.masksToBounds = true
        }
    }

    /// 默认帧：底贴容器底、高跟内容走（preferredContentSize > 0 时用它，
    /// 否则容器高一半）、顶留 56pt；宽：<821 全宽，≥821 居中 600
    ///（与 App 内容列同口径）。带 chrome 的子类重写本属性。
    override var frameOfPresentedViewInContainerView: CGRect {
        guard let container = containerView else { return .zero }
        let width: CGFloat
        if container.bounds.width >= 821 {
            width = min(600, container.bounds.width - 32)
        } else {
            width = container.bounds.width
        }
        let x = (container.bounds.width - width) / 2
        let preferred = presentedViewController.preferredContentSize.height
        let height = preferred > 0 ? preferred : container.bounds.height * 0.5
        let maxHeight = container.bounds.height * 0.88
        let h = max(0, min(height, maxHeight))
        return CGRect(x: x, y: container.bounds.height - h, width: width, height: h)
    }

    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        guard let container = containerView else { return }
        dimView.frame = container.bounds
        // 拖动中不重算 presentedView 的帧：帧 + 平移 transform 混写会跳变；
        // 拖动只改 transform、不改帧，松手复位后帧仍是拖动前那套，无需补算。
        guard let presentedView = presentedView, presentedView.transform.isIdentity else { return }
        presentedView.frame = frameOfPresentedViewInContainerView
    }

    /// 内容高变化时容器帧跟动画走：preferredContentSize 只改数值本身，
    /// 默认实现仅把容器布局标脏、帧在下一轮布局才落（不在调用方的动画块内，
    /// 故心情选择器切组时 motion.normal 块里的改高不会跟帧、只会跳变）。这里在
    /// motion.normal 内把容器布局跑完，帧与调用方的动画同速跟进；减动效直落终值。
    /// 登录 sheet 子类的同款重写已并入此处，不再各自写一份。
    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        guard let containerView = containerView else { return }
        if UIAccessibility.isReduceMotionEnabled {
            containerView.layoutIfNeeded()
        } else {
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.beginFromCurrentState], animations: {
                containerView.layoutIfNeeded()
            })
        }
    }

    override func presentationTransitionWillBegin() {
        guard let container = containerView, let presentedView = presentedView else { return }
        // VoiceOver：出现前先记 sheet 外焦点（此时焦点仍在触发控件上，出现后即被夺走）；
        // 声明模态：背后页面仍在层级里（缩 0.92 倍、压暗，未移除），不置 modal 则
        // VoiceOver 可从 sheet 内滑读到被遮的背后页面（DraftBox :387–390 同款注释）。
        if #available(iOS 17.0, *) {
            previousFocusedElement = UIAccessibility.focusedElement(using: nil) as? AnyObject
        }
        presentedView.accessibilityViewIsModal = true
        // 保存背后页面原样（每次呈现都重存，防上次残留）。
        if let backgroundView = presentingViewController.view {
            backgroundOriginalTransform = backgroundView.transform
            backgroundOriginalCornerRadius = backgroundView.layer.cornerRadius
            backgroundOriginalMasksToBounds = backgroundView.layer.masksToBounds
        }
        dimView.backgroundColor = .black
        dimView.alpha = 0
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dimTapped)))
        container.addSubview(dimView)
        let pan = makeDragPan()
        presentedView.addGestureRecognizer(pan)
        dragPan = pan
        // 初始态：遮罩透明、背后原样；动画呈现时 animator 在同一弹簧块内
        // 调 setSheetPresented(true) 驱动到终态；非动画呈现无 animator，
        // 这里直接落终态（只遮罩与背后页面，子类 chrome 自己处理）。
        applyPresentationProgress(1)
        if presentedViewController.transitionCoordinator == nil {
            applyPresentationProgress(0)
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed {
            previousFocusedElement = nil
            cleanupAfterTransition()
        } else {
            postSheetOpenFocus()
        }
    }

    override func dismissalTransitionWillBegin() {
        // 动画退场时 animator 与内容同一弹簧块驱动，这里不动；
        // 非动画退场无 animator，直接落终态。
        if presentedViewController.transitionCoordinator == nil {
            applyPresentationProgress(1)
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        dismissVelocity = 0
        if completed {
            cleanupAfterTransition()
            // VoiceOver 焦点返回：关闭完成把焦点还给出现前记下的触发元素；
            // weak 持有，触发控件复用/离屏失效即放弃返回（EmotePicker :415–425 同款）。
            if let element = previousFocusedElement {
                UIAccessibility.post(notification: .layoutChanged, argument: element)
                previousFocusedElement = nil
            }
        } else {
            // 退场被取消（本容器退场非交互式，理论上不发生）：回到出现态。
            setSheetPresented(true)
        }
    }

    private func cleanupAfterTransition() {
        dimView.removeFromSuperview()
        applyPresentationProgress(1)
    }

    /// VoiceOver：sheet 出现完成即聚焦首元素（钩子，见 BearyBottomSheetVoiceOver；
    /// 未提供时不发）。下一 runloop 再发，等布局与过渡落位后再取元素；
    /// 若期间已关闭（presentedView 已离线）则不发。未开 VoiceOver 时 post 为空操作。
    private func postSheetOpenFocus() {
        guard let element = (presentedViewController as? BearyBottomSheetVoiceOver)?.bottomSheetInitialAccessibilityElement else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.presentedView?.window != nil else { return }
            UIAccessibility.post(notification: .screenChanged, argument: element)
        }
    }

    /// VoiceOver：拖动取消后 sheet 仍开着，焦点可能留在背后页面，post 回 sheet 内
    ///（首元素；钩子未提供时落 presentedView 本身。DraftBox :1546–1554 同款钩子点）。
    private func postSheetRestoreFocus() {
        if let element = (presentedViewController as? BearyBottomSheetVoiceOver)?.bottomSheetInitialAccessibilityElement {
            UIAccessibility.post(notification: .layoutChanged, argument: element)
        } else if let presentedView = presentedView {
            UIAccessibility.post(notification: .layoutChanged, argument: presentedView)
        }
    }

    // MARK: - 遮罩与拖动

    @objc private func dimTapped() {
        requestDismiss()
    }

    /// 建一只拖动手势（与主拖动手势同 target/action/仲裁）。
    private func makeDragPan() -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(dragPan(_:)))
        pan.delegate = self
        return pan
    }

    /// 除 presentedView 之外再挂一只拖动手势，保证整张 sheet 任何位置起手都能拖。
    /// 用于 presentedView 帧之外的区域，如登录弹窗顶部 24pt chrome 条
    ///（玻璃不参与触摸、抓手只有 40×4pt，直接挂玻璃/抓手都接不到整条）。
    func installExtraDragPan(on view: UIView) {
        let pan = makeDragPan()
        view.addGestureRecognizer(pan)
        extraDragPans.append(pan)
    }

    private func isDragPan(_ gesture: UIGestureRecognizer) -> Bool {
        guard let pan = gesture as? UIPanGestureRecognizer else { return false }
        return pan === dragPan || extraDragPans.contains(pan)
    }

    /// 拖动位移：下滑 1:1 跟手；上滑按 0.25 阻力折算、上浮封顶 24pt（不扩高、不脱底，只微移）。
    private static func dragOffset(for translationY: CGFloat) -> CGFloat {
        if translationY >= 0 { return translationY }
        return max(translationY * BearyBottomSheet.upwardResistance, -24)
    }

    /// 拖动进度：下滑位移占弹窗高比例（0 = 静止，1 = 完全滑出）；
    /// 上滑/未拖动时为 0，背后页面与遮罩不动。
    private func dragProgress(for translationY: CGFloat) -> CGFloat {
        guard translationY > 0 else { return 0 }
        let height = frameOfPresentedViewInContainerView.height
        guard height > 0 else { return 0 }
        return min(1, translationY / height)
    }

    /// 触点命中的最内层滚动视图（沿 hitTest 链上找第一只 UIScrollView；无则 nil）。
    private func scrollView(at point: CGPoint) -> UIScrollView? {
        guard let presentedView = presentedView,
              let hitView = presentedView.hitTest(point, with: nil) else { return nil }
        var view: UIView? = hitView
        while let candidate = view, candidate !== presentedView {
            if let scrollView = candidate as? UIScrollView { return scrollView }
            view = candidate.superview
        }
        return nil
    }

    /// 该滚动视图还能不能往 translationY 方向滚（>0 下拉、<0 上拉）：
    /// 能滚时弹窗不动、内容先滚；滚到头了弹窗接手。边界按
    /// adjustedContentInset 算（有顶部内边距时真正的顶是 -top，不是 0），留 1pt 浮点容差。
    private func scrollViewCanScroll(_ scrollView: UIScrollView, for translationY: CGFloat) -> Bool {
        guard scrollView.isScrollEnabled else { return false }
        if translationY > 0 {
            return scrollView.contentOffset.y > -scrollView.adjustedContentInset.top + 1
        } else if translationY < 0 {
            let maxOffsetY = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
            return scrollView.contentOffset.y < maxOffsetY - 1
        }
        return false
    }

    @objc private func dragPan(_ gesture: UIPanGestureRecognizer) {
        guard let container = containerView, let presentedView = presentedView else { return }
        let translation = gesture.translation(in: container).y
        switch gesture.state {
        case .began:
            // 记下起手命中的滚动视图；本次手势内只认它，接手状态清零。
            dragScrollView = scrollView(at: gesture.location(in: presentedView))
            dragTakeoverTranslation = nil
            appliedDragOffset = 0
        case .changed:
            // 逐采样裁决。旧口径只在起手判一次：内容能滚时容器手势直接失败，
            // 整次手势再也接手不了——内容滚到头、继续往上拉，弹窗也不动，
            // 固定按钮（心情 pill、输入 sheet 底部按钮组）全程不跟手。
            // 新口径：两只 pan 同时认（见 shouldRecognizeSimultaneouslyWith），
            // 内容先滚、滚到头弹窗接手；一次手势内滚动→拖弹窗可衔接，
            // 不用抬手再拖一次；手指反向越过接手点、内容能往新方向滚时交还内容。
            if let takeover = dragTakeoverTranslation {
                let relative = translation - takeover
                if relative != 0, relative * dragTakeoverSign < 0,
                   let scrollView = dragScrollView,
                   scrollViewCanScroll(scrollView, for: relative) {
                    // 交还内容：弹窗回到接手时的静止位（恒为 0），不跳变。
                    dragTakeoverTranslation = nil
                    appliedDragOffset = 0
                    applySheetTransform(.identity)
                    applyPresentationProgress(0)
                } else {
                    let offset = Self.dragOffset(for: relative)
                    appliedDragOffset = offset
                    applySheetTransform(CGAffineTransform(translationX: 0, y: offset))
                    applyPresentationProgress(dragProgress(for: offset))
                }
            } else if let scrollView = dragScrollView, scrollViewCanScroll(scrollView, for: translation) {
                // 内容还能往该方向滚：弹窗不动（transform 已是静止态，无需重复设）。
            } else {
                // 滚到头（或无滚动内容）：接手。接手瞬间相对位移为 0、弹窗位移为 0，不跳变。
                dragTakeoverTranslation = translation
                dragTakeoverSign = translation >= 0 ? 1 : -1
                appliedDragOffset = 0
            }
        case .ended:
            let velocity = gesture.velocity(in: container).y
            dragScrollView = nil
            dragTakeoverTranslation = nil
            // 关／回弹按实际作用到弹窗的位移裁决，不按手势原始位移
            //（原始位移含内容滚动那段：只滚内容没动弹窗时不得关）。
            if appliedDragOffset > BearyBottomSheet.dismissDistance || (appliedDragOffset > 0 && velocity > BearyBottomSheet.dismissVelocity) {
                // 不清 transform：dismiss 动效从当前拖位滑下（beginFromCurrentState），
                // 避免先回弹再下滑的跳变；松手速度交给退场弹簧初速度。
                dismissVelocity = velocity
                requestDismiss()
            } else {
                restoreDrag(velocity: velocity)
            }
        case .cancelled, .failed:
            dragScrollView = nil
            dragTakeoverTranslation = nil
            restoreDrag(velocity: 0)
        default:
            break
        }
    }

    private func restoreDrag(velocity: CGFloat) {
        let restore = { [weak self] in
            guard let self = self else { return }
            self.applySheetTransform(.identity)
            self.setSheetPresented(true)
        }
        // 拖动结束时强制一次布局：拖动中 containerViewWillLayoutSubviews 为保跟手
        // 提前返回，期间键盘帧／内容高变化只记了值、未落帧；复位时把布局放进
        // 同一弹簧里（与 transform 同速回位），按钮与弹窗同一弹簧、不跳变；
        // 完成后再补一次（幂等兜底：动画块内已落过时为空操作）。
        // 旧口径只在完成回调里落帧：弹簧跑完按钮才跳变到正确位置（松手卡一下）。
        //（旧登录弹窗 restoreDrag 同款 relayout，容器化时一并带过来。）
        let relayout = { [weak self] in
            self?.containerView?.setNeedsLayout()
            self?.containerView?.layoutIfNeeded()
        }
        if UIAccessibility.isReduceMotionEnabled {
            restore()
            relayout()
            postSheetRestoreFocus()
        } else {
            // 弹回用拖拽收尾弹簧 0.26s / damping 0.7（规范 §6 统一档），初速度按松手速度归一化
            //（沿动画方向与拖动方向相反，故取负；慢拖速度小、自然接近 0；
            // 行程 ≤1pt 时归 0；行程极小而速度大时封顶 ±2，防弹簧冲过头）。
            let offset = presentedView?.transform.ty ?? 0
            let initialVelocity: CGFloat
            if abs(offset) > 1 {
                initialVelocity = max(-2, min(2, -velocity / offset))
            } else {
                initialVelocity = 0
            }
            UIView.animate(withDuration: BearyBottomSheet.dragSpringDuration, delay: 0, usingSpringWithDamping: BearyBottomSheet.dragSpringDamping, initialSpringVelocity: initialVelocity, options: [.beginFromCurrentState], animations: {
                restore()
                relayout()
            }, completion: { [weak self] _ in
                relayout()
                self?.postSheetRestoreFocus()
            })
        }
    }
}

// MARK: - 拖动与滚动仲裁

extension BearyBottomSheetPresentationController: UIGestureRecognizerDelegate {

    /// 拖动手势起手仲裁：只接竖直拖动。滚动与拖弹窗的裁决不在这里做——
    /// 旧口径在这里一次判死（内容能滚就让容器手势失败）：一次手势内内容
    /// 滚到头、继续往上拉，弹窗也接手不了，固定按钮全程不动。
    /// 新口径：两只 pan 同时认（见 shouldRecognizeSimultaneouslyWith），
    /// 滚动／拖弹窗的逐采样裁决在 dragPan 里做（内容先滚、滚到头接手）。
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer,
              isDragPan(pan),
              let presentedView = presentedView else { return false }
        let translation = pan.translation(in: presentedView)
        return abs(translation.y) > abs(translation.x)
    }

    /// 拖动与滚动的协调（2026-11-14 改口径）：两只 pan 同时认，逐采样裁决。
    /// 旧口径是一次性裁决：shouldBeRequiredToFailBy 让内容 pan 等容器手势的
    /// gestureRecognizerShouldBegin verdict——判能拖（滚到头）时容器先认、
    /// 内容 pan 认输；判不能拖（内容还能往该方向滚）时容器立刻失败、内容 pan
    /// 接手。问题是一次判死：整次手势内内容滚到头、继续往上拉，容器手势
    /// 已经失败、再也接手不了，弹窗不动、固定按钮全程不跟手。
    /// 新口径：容器 pan 与内容 pan 同时认（UIScrollView 允许祖先视图的 pan
    /// 同时认，见 shouldRecognizeSimultaneouslyWith），滚动／拖弹窗的
    /// 逐采样裁决在 dragPan 里做——内容先滚、滚到头弹窗接手（接手点起算、
    /// 接手瞬间位移为 0），手指反向越过接手点、内容能往新方向滚时交还内容。
    /// 点按不受影响（点按不经过 pan 认出）；失败依赖不再需要，返回 false
    ///（旧注释里“依赖方向不能写反”的教训仍成立：这里绝不能用
    /// shouldRequireFailureOf 让容器等内容先失败——内容到顶下拉时内部 pan
    /// 照常认出（回弹），容器永远等不到失败，弹窗在内容区拖不动）。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard isDragPan(gestureRecognizer),
              let otherPan = otherGestureRecognizer as? UIPanGestureRecognizer,
              let otherView = otherPan.view,
              let presentedView = presentedView,
              otherView.isDescendant(of: presentedView),
              otherView is UIScrollView else { return false }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return false
    }
}

// MARK: - 弹簧进退场动画

final class BearyBottomSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool
    private weak var presentationController: BearyBottomSheetPresentationController?

    init(isPresenting: Bool, presentationController: BearyBottomSheetPresentationController? = nil) {
        self.isPresenting = isPresenting
        self.presentationController = presentationController
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return UIAccessibility.isReduceMotionEnabled ? 0 : BearyBottomSheet.springDuration
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
                presentationController?.setSheetPresented(true)
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: BearyBottomSheet.springDamping, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: {
                toView.transform = .identity
                self.presentationController?.setSheetPresented(true)
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
                presentationController?.setSheetPresented(false)
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            // 退场初速度：拖动甩关时把松手速度归一化传给弹簧（1.0 = 一秒走完全程）；
            // 普通关闭速度为 0。beginFromCurrentState 保证从当前拖位滑下、不先回弹。
            let velocity = presentationController?.dismissVelocity ?? 0
            let initialVelocity: CGFloat = offset > 0 ? max(0, min(2, velocity / offset)) : 0
            UIView.animate(withDuration: duration, delay: 0, usingSpringWithDamping: BearyBottomSheet.springDamping, initialSpringVelocity: initialVelocity, options: [.beginFromCurrentState], animations: {
                fromView.transform = CGAffineTransform(translationX: 0, y: offset)
                self.presentationController?.setSheetPresented(false)
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}
