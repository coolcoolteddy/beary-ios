import UIKit

// ===== 登录底 sheet 弹窗（Li 2026-11-02 批准施工：整页登录改弹窗）=====
// 形态：底 sheet + 顶栏同款液态玻璃（BearyGlass.effectView，中性 bg 52% tint；
// iOS 26+ 真 UIGlassEffect，低版本降级系统毛玻璃——与顶栏/底栏同配方）。
// 注意：BearyGlass token 原口径“窗口/弹窗不用系统材质”对登录弹窗有 Li 批准的
// 唯一例外（见 BearyGlass 注释）；不要把本 sheet 的玻璃“统一”回实色底。
// 容器：BearyLoginSheet.make() 只建 sheet 模式登录页、不 present；调用点按原样
// 接回调后再 present（与原整页顺序一致，含 dismiss 调用方与会话守卫）。
// 呈现走共享底部弹窗容器 BearyBottomSheet（transitioningDelegate +
// presentationController 工厂）：出现弹簧 0.38s / damping 0.7 从底部升起，
// 背后页面同步缩 0.92 倍、圆角 16pt、遮罩压暗 0.45；拖动整张弹窗可拖，
// 下滑 1:1 跟手、上滑按 0.3 阻力折算，松手下拖超高 1/3 或下甩速度 > 1000pt/s
// 关闭、否则弹簧弹回；关闭时背后页面同步恢复。遮罩点按与拖动关闭都走
// requestDismiss 重写 → cancelFromSheet（= 关闭钮路径，先停倒计时与在途任务、
// 再交 onCancelled），容器不得绕开它直接 dismiss，否则添加账号会话守卫
// stays armed。减动效开时出现/关闭瞬时、拖动关闭无动画直接关。
// 尺寸：高跟内容走（登录页 preferredContentSize），顶留 56pt；宽：<821 全宽，
// ≥821 居中 600（与 App 内容列同口径）；停靠键盘时 sheet 底贴键盘顶，
// 浮动/分屏键盘不动 sheet（页内滚动 inset 已处理遮挡）。
// 本文件只留登录弹窗自己的 chrome（玻璃/抓手/阴影）与键盘跟随逻辑；
// 遮罩、背后页面、弹簧进退场、拖动手势一律走 BearyBottomSheet 容器。
// 键盘逻辑（keyboardTopY / updateKeyboardTop / animateLayoutForKeyboard）
// 保持现行 main 原样不动，L3/M5 相关改动另支 #913 在做，合入时再 rebase。
// transitioningDelegate 由登录页自身强持有（loginSheetDelegate），随页释放。

enum BearyLoginSheet {
    /// 建一个 sheet 模式登录页（BearyLoginViewController.sheetMode = true +
    /// 底 sheet transitioning），不 present；调用点接完回调后自行 present。
    static func make() -> BearyLoginViewController {
        let vc = BearyLoginViewController()
        vc.sheetMode = true
        let delegate = BearyBottomSheetTransitioningDelegate { presented, presenting, _ in
            BearyLoginSheetPresentationController(presentedViewController: presented, presenting: presenting)
        }
        vc.loginSheetDelegate = delegate
        vc.transitioningDelegate = delegate
        vc.modalPresentationStyle = .custom
        // 2026-11-04：进场前先算一次内容高，首帧不用 666 回退高、随后不再大跳变；
        // 安全区此时未进窗口为 0，落窗后 viewDidLayoutSubviews 按真实安全区跟帧补齐。
        vc.loadViewIfNeeded()
        vc.view.setNeedsLayout()
        vc.view.layoutIfNeeded()
        return vc
    }
}

// MARK: - Presentation controller

private final class BearyLoginSheetPresentationController: BearyBottomSheetPresentationController {

    /// 抓手区高：sheet 顶部的玻璃 chrome 区（抓手 10–14 + 余量），登录页内容从其下开始。
    private static let chromeHeight: CGFloat = 24
    /// sheet 顶距容器顶的最小留白。
    private static let topMargin: CGFloat = 56
    /// 宽屏阈值与列宽：与 App 内容列同口径（≥821 居中 600）。
    private static let wideThreshold: CGFloat = 821
    private static let wideSheetWidth: CGFloat = 600
    /// 首帧未算出内容高时的回退内容高（随后 viewDidLayoutSubviews 会纠正）。
    private static let fallbackContentHeight: CGFloat = 666

    private let shadowView = UIView()
    private let glassView = BearyGlass.effectView(tint: BearyGlass.neutralTint)
    private let grabberView = UIView()
    /// 顶部 24pt chrome 条的拖动热区：玻璃不参与触摸（BearyGlass 口径）、
    /// 抓手只有 40×4pt，整条都接不到拖动；透明热区盖住整条、挂同款拖动
    /// 手势，抓手区也能拖（BearyGrabHitView，见 BearyComposerPickers 同款用法）。
    /// 关闭钮在内容区（presentedView 内），不在本条内，无需透传。
    private let chromeHitView = BearyGrabHitView()
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

    /// 遮罩点按与拖动关闭都走登录页取消路径（先停倒计时与在途任务），
    /// 不得绕开它直接 dismiss（见文件头注释）。
    override func requestDismiss() {
        (presentedViewController as? BearyLoginViewController)?.cancelFromSheet()
    }

    /// 拖动/弹回时 chrome 与内容同一 transform（容器调本方法时已在动画块内）。
    override func applySheetTransform(_ transform: CGAffineTransform) {
        super.applySheetTransform(transform)
        shadowView.transform = transform
        glassView.transform = transform
        grabberView.transform = transform
        chromeHitView.transform = transform
    }

    /// 出现/关闭终态：容器处理遮罩与背后页面，这里同步 chrome 终态
    ///（animator 同一弹簧块内调，保证玻璃边与内容边不错位）。
    override func setSheetPresented(_ presented: Bool) {
        super.setSheetPresented(presented)
        setChromePresented(presented)
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
        chromeHitView.frame = CGRect(x: sheet.minX, y: sheet.minY, width: sheet.width, height: Self.chromeHeight)
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
        // 先走容器：摆遮罩、挂拖动手势、置遮罩与背后页面初始态。
        super.presentationTransitionWillBegin()
        guard let container = containerView else { return }
        shadowView.backgroundColor = .clear
        BearyShadow.applyRaised(to: shadowView.layer)
        container.addSubview(shadowView)
        container.addSubview(glassView)
        grabberView.backgroundColor = BearyColors.line
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        container.addSubview(grabberView)
        // 顶部 24pt chrome 条在 presentedView 帧之外，容器主拖动手势挂不到它；
        // 透明热区盖住整条、挂同款拖动手势，抓手区也能拖。grabberView 本身不交互，
        // 触点落到热区上；关闭钮在内容区内，不在本条内，无需透传。
        grabberView.isUserInteractionEnabled = false
        installExtraDragPan(on: chromeHitView)
        container.addSubview(chromeHitView)
        // 这里只摆 chrome 初始态（屏外），不另起 coordinator alongside 动画——
        // 动画呈现时 chrome 由 animator 与内容同一弹簧块驱动（见 setSheetPresented）；
        // 非动画呈现（减动效等）无 animator，这里直接落终态。
        let offscreen = CGAffineTransform(translationX: 0, y: sheetFrame(for: container.bounds).height)
        shadowView.transform = offscreen
        glassView.transform = offscreen
        grabberView.transform = offscreen
        chromeHitView.transform = offscreen
        if presentedViewController.transitionCoordinator == nil {
            setChromePresented(true)
        }
    }

    /// chrome 进场/退场终态（只赋值、不自带动效，调用方须在动画块内调，
    /// 否则 transform 直落终值无过渡）。
    func setChromePresented(_ presented: Bool) {
        if presented {
            shadowView.transform = .identity
            glassView.transform = .identity
            grabberView.transform = .identity
            chromeHitView.transform = .identity
        } else {
            guard let container = containerView else { return }
            let offscreen = CGAffineTransform(translationX: 0, y: sheetFrame(for: container.bounds).height)
            shadowView.transform = offscreen
            glassView.transform = offscreen
            grabberView.transform = offscreen
            chromeHitView.transform = offscreen
        }
    }

    override func presentationTransitionDidEnd(_ completed: Bool) {
        super.presentationTransitionDidEnd(completed)
        if !completed {
            removeChrome()
        }
    }

    override func dismissalTransitionWillBegin() {
        super.dismissalTransitionWillBegin()
        // 动画退场时 chrome 由退场 animator 与内容同一弹簧块驱动，
        // 这里不动；非动画退场无 animator，直接落终态。
        if presentedViewController.transitionCoordinator == nil {
            setChromePresented(false)
        }
    }

    override func dismissalTransitionDidEnd(_ completed: Bool) {
        super.dismissalTransitionDidEnd(completed)
        if completed {
            removeChrome()
        }
    }

    private func removeChrome() {
        shadowView.removeFromSuperview()
        glassView.removeFromSuperview()
        grabberView.removeFromSuperview()
        chromeHitView.removeFromSuperview()
    }

    // 内容高变化的跟帧动画由基类 BearyBottomSheetPresentationController
    // 的 preferredContentSizeDidChange 统一做（motion.normal 跟帧、减动效直落），
    // 此处不再重复写一份；只调 super。
    override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
        super.preferredContentSizeDidChange(forChildContentContainer: container)
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
    /// 停靠→悬浮只发 keyboardWillChangeFrame、不发 keyboardWillHide：键盘不再贴底时
    /// 在这里把旧的停靠顶边清掉、落回容器底，否则 sheet 一直停在旧高度。
    /// 与 Toast 同口径：帧须与容器相交且触到容器底边才认贴底；收起途中的
    /// WillChangeFrame 终帧在屏外（minY 已过底边）同判为无，不再误认贴底。
    private func updateKeyboardTop(from note: Notification) {
        guard let container = containerView,
              let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frameInContainer = container.convert(value.cgRectValue, from: nil)
        let bounds = container.bounds
        guard frameInContainer.minY < bounds.maxY - 1,
              frameInContainer.maxY >= bounds.maxY - 1,
              frameInContainer.intersects(bounds) else {
            // 键盘不再贴底（iPad 悬浮/分屏／已移出屏幕）：清掉旧的停靠顶边并重算落点；
            // 已是 nil 时不重复布局。
            guard keyboardTopY != nil else { return }
            keyboardTopY = nil
            animateLayoutForKeyboard(note)
            return
        }
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
            return
        }
        // 2026-11-05 M5：布局一次落到目标，视觉过渡只用 transform。
        // 拖拽/进退场期间 chrome 与内容正用 transform（见 BearyBottomSheet
        // 容器拖动 / setChromePresented），不叠加键盘 transform，直接落布局。
        guard let presentedView = presentedView,
              presentedView.transform.isIdentity,
              shadowView.transform.isIdentity,
              glassView.transform.isIdentity,
              grabberView.transform.isIdentity,
              chromeHitView.transform.isIdentity else {
            container.layoutIfNeeded()
            return
        }
        // 先读当前视觉位置（presentation 层含在途动画），再落布局、
        // 由旧位置起播回 0；连续键盘事件每次都从实际视觉位置重算，
        // 中断也不留残余偏移。模型值起播时即为 .identity，播完自然清零。
        let hadFrame = shadowView.frame.height > 0
        let oldVisualY = shadowView.layer.presentation()?.frame.minY ?? shadowView.frame.minY
        container.layoutIfNeeded()
        guard hadFrame else { return }
        let dy = oldVisualY - shadowView.frame.minY
        guard dy != 0 else { return }
        let offset = CGAffineTransform(translationX: 0, y: dy)
        presentedView.transform = offset
        shadowView.transform = offset
        glassView.transform = offset
        grabberView.transform = offset
        chromeHitView.transform = offset
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: { [weak self] in
            self?.presentedView?.transform = .identity
            self?.shadowView.transform = .identity
            self?.glassView.transform = .identity
            self?.grabberView.transform = .identity
            self?.chromeHitView.transform = .identity
        })
    }
}
