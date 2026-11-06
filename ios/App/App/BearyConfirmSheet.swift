import UIKit

// ===== 审计 r16 第 16 项：共享确认底 sheet =====
// 五处系统 UIAlertController .alert 改走统一底部弹窗：
// 置顶替换（BearyDiaryPin.confirmReplacement）、取消关注
// （BearyFriends.confirmUnfollow / confirmUnfollowAlert）、删除日记
// （SceneDelegate.confirmAndDeleteEntry）、引用权限冲突 5 处
// （BearyQuoteGate.presentPublicGate / gateEditorPublish /
// promptStoredPrivateQuote / confirmPrivateToggleIfQuoted）、回收站彻底删除
// （BearyTrashViewController.purgeTapped）。
// 样板 = 登录底 sheet（BearyLoginSheet）：同款 chrome（BearySheetChrome：
// 顶圆角 20、抓手 40×4、遮罩 0.45）、同款拖动口径（BearySheetDrag：
// 下滑跟手、上滑 0.25 阻尼、超 80pt 或速度 > 600 关闭，否则 0.25s 弹回）、
// 同款进退场（入场 0.25s easeOut 上滑、退场 0.30s 弹簧、减动效直显终值、
// 动效只走 transform/opacity）。与登录页不同：确认弹窗无输入框，
// 故本文件不含键盘逻辑；背板不用玻璃——玻璃 token 只允登录底 sheet 用
// 系统材质（Li 2026-11-02 批准的唯一例外），其余弹窗走实色底。
// 与 #920（feat/bottom-sheet-container，未合入 main）的关系：#920 引进的
// BearyBottomSheet 是未来的共享容器；本文件自建轻量 presentationController
// 只复用 chrome/drag 共享口径，不复制登录页键盘代码、不依赖 #920。
// #920 合入后应把本 sheet 迁到 BearyBottomSheet 容器上（届时删本文件的
// presentation/animator，只留内容 VC 与 present 入口）；合入前本支独立可用。
// 语义：原 alert 的标题/正文/按钮文案与顺序一字不动；点按某行先关 sheet
// 再跑原 handler（与 UIAlertAction 点按后即 dismiss 同口径）；叉叉 /
// 遮罩点按 / 下滑关闭一律走 .cancel 动作的 handler（无 .cancel 时走
// onDismissWithoutAction，未传则什么都不做）；危险动作（.destructive）
// 红底白字、普通确认墨底、取消 faint 底，与系统 alert 的样式区分同义。
// 系统分享面板、系统权限请求不要强行替换——不在本文件范围。

// MARK: - 动作

enum BearyConfirmSheetActionStyle {
    case normal
    case destructive
    case cancel
}

struct BearyConfirmSheetAction {
    let title: String
    let style: BearyConfirmSheetActionStyle
    let handler: (() -> Void)?

    init(title: String, style: BearyConfirmSheetActionStyle = .normal, handler: (() -> Void)? = nil) {
        self.title = title
        self.style = style
        self.handler = handler
    }
}

// MARK: - 入口

enum BearyConfirmSheet {

    /// 弹统一确认底 sheet。调用点原有的 BearyPresentGuard 守卫一字不动
    /// （引用门禁四函数仍先守卫；其余调用点此前无守卫，如回收站左滑菜单
    /// 回调时菜单尚未 dismiss 完、守卫会误拦，故本入口不另加守卫）。
    /// - Parameters:
    ///   - title/message: 原 alert 的标题/正文，一字不动（可为 nil）。
    ///   - actions: 原 alert 的全部 action，顺序照原样；至多一个 .cancel。
    ///   - onDismissWithoutAction: 无 .cancel 动作时，叉叉/遮罩/拖动关闭的
    ///     回调（如“放弃公开”）；有 .cancel 时关闭即走该 cancel 动作的
    ///     handler，本回调不调用。
    static func present(from vc: UIViewController, title: String?, message: String?,
                        actions: [BearyConfirmSheetAction],
                        onDismissWithoutAction: (() -> Void)? = nil) {
        let sheet = BearyConfirmSheetViewController(title: title, message: message,
                                                    actions: actions,
                                                    onDismissWithoutAction: onDismissWithoutAction)
        let delegate = BearyConfirmSheetTransitioningDelegate()
        sheet.confirmSheetDelegate = delegate
        sheet.transitioningDelegate = delegate
        sheet.modalPresentationStyle = .custom
        // 2026-11-04 登录 sheet 同款：进场前先按发起页宽度给 sheet 一个临时宽、
        // 再布局量内容高，首帧不用回退高、随后不再大跳变。
        let hostWidth = vc.view.bounds.width
        let sheetWidth: CGFloat = hostWidth >= 821 ? min(600, hostWidth - 32) : max(hostWidth, 320)
        sheet.view.bounds = CGRect(x: 0, y: 0, width: sheetWidth, height: 0)
        sheet.loadViewIfNeeded()
        sheet.view.setNeedsLayout()
        sheet.view.layoutIfNeeded()
        vc.present(sheet, animated: BearyMotion.animated(true))
    }
}

// MARK: - 内容 VC

private final class BearyConfirmSheetViewController: UIViewController {

    /// transitioningDelegate 是 weak 持有：与登录页（loginSheetDelegate）同款，
    /// 由本 VC 自身强持有，随页释放。
    var confirmSheetDelegate: BearyConfirmSheetTransitioningDelegate?

    private let titleText: String?
    private let messageText: String?
    private let actions: [BearyConfirmSheetAction]
    private let onDismissWithoutAction: (() -> Void)?

    /// 至多一个 .cancel 动作：叉叉/遮罩/拖动关闭即走它的 handler。
    private var cancelAction: BearyConfirmSheetAction? {
        actions.first(where: { $0.style == .cancel })
    }

    /// 只解析一次：点按行 / 关闭入口任一先到即定局，后到的直接丢弃，
    /// 防重复 dismiss 与 handler 双跑。
    private var resolved = false

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let closeButton = BearyButton.closeButton()

    init(title: String?, message: String?, actions: [BearyConfirmSheetAction],
         onDismissWithoutAction: (() -> Void)?) {
        self.titleText = title
        self.messageText = message
        self.actions = actions
        self.onDismissWithoutAction = onDismissWithoutAction
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true

        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 17))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        titleLabel.text = titleText
        titleLabel.accessibilityTraits = .header
        titleLabel.isHidden = (titleText ?? "").isEmpty

        messageLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = BearyColors.gray
        messageLabel.numberOfLines = 0
        messageLabel.text = messageText
        messageLabel.isHidden = (messageText ?? "").isEmpty

        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let headerRow = UIStackView(arrangedSubviews: [titleLabel, closeButton])
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        headerRow.spacing = 12
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        let actionStack = UIStackView()
        actionStack.axis = .vertical
        actionStack.spacing = 8
        for (index, action) in actions.enumerated() where action.style != .cancel {
            actionStack.addArrangedSubview(actionButton(for: action, at: index))
        }

        let contentStack = UIStackView(arrangedSubviews: [headerRow, messageLabel, actionStack])
        contentStack.axis = .vertical
        contentStack.spacing = 8
        contentStack.setCustomSpacing(16, after: headerRow)
        contentStack.setCustomSpacing(16, after: messageLabel)
        if let cancel = cancelAction, let cancelIndex = actions.firstIndex(where: { $0.style == .cancel }) {
            contentStack.addArrangedSubview(actionButton(for: cancel, at: cancelIndex))
            contentStack.setCustomSpacing(12, after: actionStack)
        }
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 内容高跟布局走：转屏 / 大字号档位变化时重算 preferredContentSize，
        // presentationController 经 preferredContentSizeDidChange 跟帧。
        // 宽为 0（尚未进窗）时不算，等真实宽落定后再算。
        guard view.bounds.width > 0 else { return }
        let target = CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height)
        let height = ceil(view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
        if abs(preferredContentSize.height - height) > 0.5 {
            preferredContentSize = CGSize(width: 0, height: height)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // VoiceOver 进 sheet 即落焦点：有标题落标题、无标题落正文、都没有落关闭钮。
        let focus: AnyObject
        if !titleLabel.isHidden {
            focus = titleLabel
        } else if !messageLabel.isHidden {
            focus = messageLabel
        } else {
            focus = closeButton
        }
        UIAccessibility.post(notification: .screenChanged, argument: focus)
    }

    private func actionButton(for action: BearyConfirmSheetAction, at index: Int) -> UIButton {
        let button = BearyHit44Button(type: .custom)
        button.setTitle(action.title, for: .normal)
        button.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 16))
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.layer.cornerRadius = BearyCorners.single
        switch action.style {
        case .normal:
            button.backgroundColor = BearyColors.ink
            button.setTitleColor(BearyColors.bg, for: .normal)
        case .destructive:
            button.backgroundColor = BearyColors.red
            button.setTitleColor(.white, for: .normal)
        case .cancel:
            button.backgroundColor = BearyColors.faint
            button.setTitleColor(BearyColors.ink, for: .normal)
        }
        button.bearyAddPressFeedback()
        button.addTarget(self, action: #selector(actionTapped(_:)), for: .touchUpInside)
        // 动作下标经 tag 无法传 Int：用 accessibilityIdentifier 搭载，点按时再查表。
        button.accessibilityIdentifier = "\(index)"
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        return button
    }

    @objc private func actionTapped(_ sender: UIButton) {
        guard let index = Int(sender.accessibilityIdentifier ?? ""),
              actions.indices.contains(index) else { return }
        resolve(with: actions[index].handler)
    }

    @objc private func closeTapped() {
        resolve(with: dismissHandler())
    }

    /// 叉叉 / 遮罩 / 拖动关闭：有 .cancel 走它的 handler，无则走
    /// onDismissWithoutAction（未传则什么都不做）。
    func requestDismiss() {
        resolve(with: dismissHandler())
    }

    private func dismissHandler() -> (() -> Void)? {
        if let cancel = cancelAction { return cancel.handler }
        return onDismissWithoutAction
    }

    private func resolve(with handler: (() -> Void)?) {
        guard !resolved else { return }
        resolved = true
        dismiss(animated: BearyMotion.animated(true)) { handler?() }
    }
}

// MARK: - Transitioning delegate

private final class BearyConfirmSheetTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    private weak var sheetPresentationController: BearyConfirmSheetPresentationController?

    func presentationController(forPresented presented: UIViewController, presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
        let pc = BearyConfirmSheetPresentationController(presentedViewController: presented, presenting: presenting)
        sheetPresentationController = pc
        return pc
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BearyConfirmSheetAnimator(isPresenting: true, presentationController: sheetPresentationController)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        BearyConfirmSheetAnimator(isPresenting: false, presentationController: sheetPresentationController)
    }
}

// MARK: - Presentation controller（登录 sheet 同款 chrome/drag，减键盘逻辑）

private final class BearyConfirmSheetPresentationController: UIPresentationController {

    /// 抓手区高：sheet 顶部的 chrome 区（抓手 10–14 + 余量），内容从其下开始。
    private static let chromeHeight: CGFloat = 24
    /// sheet 顶距容器顶的最小留白。
    private static let topMargin: CGFloat = 56
    /// 宽屏阈值与列宽：与 App 内容列同口径（≥821 居中 600）。
    private static let wideThreshold: CGFloat = 821
    private static let wideSheetWidth: CGFloat = 600
    /// 首帧未算出内容高时的回退内容高（present 前已预量，正常路径不走这里）。
    private static let fallbackContentHeight: CGFloat = 320

    private let scrimView = UIView()
    private let shadowView = UIView()
    private let panelView = UIView()
    private let grabberView = UIView()
    private let dragStripView = UIView()
    private var lastShadowBounds: CGRect = .zero

    /// Sheet 整框（含顶 chrome 区）：底贴容器底，高跟内容走、顶留白钳制。
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
        let maxHeight = containerBounds.height - Self.topMargin
        if sheetHeight > maxHeight { sheetHeight = max(0, maxHeight) }
        return CGRect(x: x, y: containerBounds.height - sheetHeight, width: width, height: sheetHeight)
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
        panelView.frame = sheet
        panelView.backgroundColor = BearyColors.bg
        panelView.layer.cornerRadius = BearySheetChrome.topCornerRadius
        panelView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        panelView.clipsToBounds = true
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
        BearyShadow.applyRaised(to: shadowView.layer)
        container.addSubview(shadowView)
        container.addSubview(panelView)
        grabberView.backgroundColor = BearyColors.line
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        container.addSubview(grabberView)
        dragStripView.backgroundColor = .clear
        dragStripView.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(dragPan(_:))))
        container.addSubview(dragStripView)
        // 只摆初始态（屏外 + 遮罩透明），不另起 coordinator alongside 动画——
        // chrome 由 animator 与内容同一动画块驱动（见 setChromePresented）；
        // 非动画呈现（减动效等）无 animator，这里直接落终态。
        let offscreen = CGAffineTransform(translationX: 0, y: sheetFrame(for: container.bounds).height)
        shadowView.transform = offscreen
        panelView.transform = offscreen
        grabberView.transform = offscreen
        dragStripView.transform = offscreen
        scrimView.alpha = 0
        if presentedViewController.transitionCoordinator == nil {
            setChromePresented(true)
        }
    }

    /// chrome 进场/退场终态（只赋值、不自带动效，调用方须在动画块内调，
    /// 否则 transform/alpha 直落终值无过渡）。
    func setChromePresented(_ presented: Bool) {
        if presented {
            scrimView.alpha = 1
            shadowView.transform = .identity
            panelView.transform = .identity
            grabberView.transform = .identity
            dragStripView.transform = .identity
        } else {
            guard let container = containerView else { return }
            let offscreen = CGAffineTransform(translationX: 0, y: sheetFrame(for: container.bounds).height)
            scrimView.alpha = 0
            shadowView.transform = offscreen
            panelView.transform = offscreen
            grabberView.transform = offscreen
            dragStripView.transform = offscreen
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        if !completed {
            removeChrome()
        }
    }

    override func dismissalTransitionWillBegin() {
        // 动画退场时 chrome 由退场 animator 与内容同一动画块驱动，这里不动；
        // 非动画退场无 animator，直接落终态。
        if presentedViewController.transitionCoordinator == nil {
            setChromePresented(false)
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
        panelView.removeFromSuperview()
        grabberView.removeFromSuperview()
        dragStripView.removeFromSuperview()
    }

    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
        guard let containerView = containerView else { return }
        // 内容高变化（转屏 / 字号档位）时 0.25s 跟帧走；减动效直落终值。
        if UIAccessibility.isReduceMotionEnabled {
            containerView.layoutIfNeeded()
        } else {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
                containerView.layoutIfNeeded()
            })
        }
    }

    // MARK: - 遮罩与拖动

    @objc private func scrimTapped() {
        (presentedViewController as? BearyConfirmSheetViewController)?.requestDismiss()
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
                (presentedViewController as? BearyConfirmSheetViewController)?.requestDismiss()
            } else {
                restoreDrag(velocity: velocity)
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
        panelView.transform = transform
        grabberView.transform = transform
        dragStripView.transform = transform
        scrimView.alpha = BearySheetDrag.scrimAlpha(forDragOffset: offset, sheetHeight: sheetHeight)
    }

    private func restoreDrag(velocity: CGFloat = 0) {
        let restore = {
            self.presentedView?.transform = .identity
            self.shadowView.transform = .identity
            self.panelView.transform = .identity
            self.grabberView.transform = .identity
            self.dragStripView.transform = .identity
            self.scrimView.alpha = 1
        }
        if UIAccessibility.isReduceMotionEnabled {
            restore()
        } else {
            // 拖拽收尾统一弹簧 0.30s／damping 0.7＋松手速度（取消/失败时速度为 0）。
            let offset = presentedView?.transform.ty ?? 0
            UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: BearySheetDrag.restoreSpringVelocity(velocity: velocity, offset: offset), options: [], animations: restore)
        }
    }
}

// MARK: - Slide animator

private final class BearyConfirmSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {

    private let isPresenting: Bool
    // chrome 与内容同一动画块——入场 0.25s curveEaseOut；退场走拖拽收尾
    // 统一弹簧 0.30s／damping 0.7（登录 sheet 同口径）。
    private weak var presentationController: BearyConfirmSheetPresentationController?

    init(isPresenting: Bool, presentationController: BearyConfirmSheetPresentationController? = nil) {
        self.isPresenting = isPresenting
        self.presentationController = presentationController
        super.init()
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return UIAccessibility.isReduceMotionEnabled ? 0 : (isPresenting ? 0.25 : 0.30)
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
                presentationController?.setChromePresented(true)
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                toView.transform = .identity
                self.presentationController?.setChromePresented(true)
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
                presentationController?.setChromePresented(false)
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
                return
            }
            UIView.animate(withDuration: 0.30, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0, options: [.beginFromCurrentState], animations: {
                fromView.transform = CGAffineTransform(translationX: 0, y: offset)
                self.presentationController?.setChromePresented(false)
            }, completion: { _ in
                transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
            })
        }
    }
}
