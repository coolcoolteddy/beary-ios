import UIKit

// ===== 底部 sheet：系统 UISheetPresentationController（自研容器退役）=====
// 全 App 底部 sheet 的唯一呈现入口（2026-11-20 移植支）：自研容器
// 整类删除，各 sheet 只留内容 VC＋show()，呈现一律走本文件。
// 保留的行为：抓手下滑关闭、点外面收起、关闭有退场动画（系统默认）；
// 一律不要 ×（各 sheet 自带 closeButton 已删，登录页自身的关闭行除外）；
// 上滑不动（单 detent，无可扩档）；高度自动适配内容；列表 sheet 间隙仍按
// BearySheetChrome 的 8/6/10/8（各页内容不动）。
// 高度：custom detent（读 preferredContentSize，封顶 88% 容器高），
// 自动贴合内容（登录等高内容 sheet 也按内容高，不留空）。
// 键盘：输入型 sheet（输入框／标签／地点）的停靠键盘顶升由各页内
// BearySheetKeyboardAvoidance 做（只跟停靠键盘，浮动/分屏不动，旧口径）；
// 登录页自带 inset 处理，不动。
// 系统 sheet 做不到旧容器那套，迁移带来的变化（见 PR 正文）：背后页面不再
// 缩 0.92（只压暗）；登录 sheet 的玻璃 chrome 条退役、改实色 surface3；
// 出现/消失走系统弹簧，不再是 0.38s/damping 0.7 定制弹簧；iPad 宽屏 600
// iPad 宽屏 600 居中靠 widthFollowsPreferredContentSizeWhenEdgeAttached 保证。
// 部署目标 iOS 16.0。

/// 内容高 sizing：各 sheet VC 已有的 updatePreferredContentSize(extraBottomInset:)。
/// 登录页不走本协议（它在 viewDidLayoutSubviews 里直接算 preferredContentSize）。
protocol BearySystemSheetSizing: AnyObject {
    func updatePreferredContentSize(extraBottomInset: CGFloat)
}

enum BearySystemSheet {

    private static let customDetentIdentifier = UISheetPresentationController.Detent.Identifier("bearySystemSheetContent")
    /// 底 sheet 高封顶（旧容器口径：min(内容高, 88% 容器高)）。
    private static let maxHeightRatio: CGFloat = 0.88

    /// 标准弹出：按 presenter 宽算 sheet 宽并预排一次内容高，再配系统 sheet 并 present。
    /// 调用方 show() 原有的 loadViewIfNeeded／frame／layout／updatePreferredContentSize
    /// 由本方法统一做，不再各写一套。
    static func present(_ sheet: UIViewController, from presenter: UIViewController) {
        sheet.view.backgroundColor = BearyColors.surface3
        sheet.loadViewIfNeeded()
        let presenterWidth = presenter.view.bounds.width
        let sheetWidth: CGFloat = presenterWidth >= 821 ? min(600, presenterWidth - 32) : presenterWidth
        sheet.view.frame = CGRect(x: 0, y: 0, width: max(sheetWidth, 1), height: 800)
        sheet.view.setNeedsLayout()
        sheet.view.layoutIfNeeded()
        if let sizing = sheet as? BearySystemSheetSizing {
            sizing.updatePreferredContentSize(extraBottomInset: presenter.view.safeAreaInsets.bottom)
        }
        if sheet.preferredContentSize.width <= 0 {
            sheet.preferredContentSize.width = sheetWidth
        }
        configure(sheet)
        presenter.present(sheet, animated: BearyMotion.animated(true)) {
            installOutsideTapDismiss(for: sheet)
        }
    }

    /// 只配系统 sheet、不 present（登录 sheet 的 make() 用：调用方随后自行 present）。
    /// 调用方须先 loadViewIfNeeded＋layoutIfNeeded 算好 preferredContentSize，
    /// 再调本方法（登录页 make() 内即此顺序）。
    static func configure(_ sheet: UIViewController) {
        sheet.view.backgroundColor = BearyColors.surface3
        sheet.modalPresentationStyle = .pageSheet
        guard let spc = sheet.sheetPresentationController else { return }
        spc.prefersGrabberVisible = true
        spc.preferredCornerRadius = BearySheetChrome.topCornerRadius
        spc.prefersScrollingExpandsWhenScrolledToEdge = false
        spc.detents = detents(for: sheet)
        spc.selectedDetentIdentifier = spc.detents.first?.identifier
        spc.widthFollowsPreferredContentSizeWhenEdgeAttached = true
    }

    /// 内容高变化后重算 detent（custom detent 用；未呈现／非系统 sheet 时无操作）。
    /// 各页在 preferredContentSize 真变时调一次（updatePreferredContentSize 内）。
    static func refreshDetentsIfNeeded(for vc: UIViewController) {
        guard vc.isViewLoaded, vc.view.window != nil else { return }
        guard let spc = vc.sheetPresentationController else { return }
        guard spc.detents.contains(where: { $0.identifier == customDetentIdentifier }) else { return }
        spc.animateChanges {
            spc.detents = detents(for: vc)
        }
    }

    private static func detents(for sheet: UIViewController) -> [UISheetPresentationController.Detent] {
        [customDetent(for: sheet)]
    }

    private static func customDetent(for sheet: UIViewController) -> UISheetPresentationController.Detent {
        UISheetPresentationController.Detent.custom(identifier: customDetentIdentifier) { [weak sheet] context in
            let contentHeight = sheet?.preferredContentSize.height ?? 0
            let maxHeight = context.maximumDetentValue * maxHeightRatio
            guard contentHeight > 0 else { return maxHeight * 0.5 }
            return min(contentHeight, maxHeight)
        }
    }

    /// 点外面收起：系统 sheet 默认点遮罩不关，容器上挂点按手势补齐（旧容器口径）。
    /// 手势挂 containerView 上，点按落在 sheet 框内时忽略（按钮／滚动照常）。
    private static func installOutsideTapDismiss(for sheet: UIViewController) {
        guard let containerView = sheet.sheetPresentationController?.containerView else { return }
        let handler = OutsideTapDismissHandler(sheet: sheet)
        let tap = UITapGestureRecognizer(target: handler, action: #selector(OutsideTapDismissHandler.handleTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = handler
        containerView.addGestureRecognizer(tap)
    }

    /// 点外手势的 target／delegate：由手势强持有，随 containerView 释放；sheet 只弱引用。
    private final class OutsideTapDismissHandler: NSObject, UIGestureRecognizerDelegate {
        private weak var sheet: UIViewController?

        init(sheet: UIViewController) {
            self.sheet = sheet
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let sheet = sheet, let containerView = gesture.view, let presentedView = sheet.view else { return }
            let point = gesture.location(in: containerView)
            guard !presentedView.frame.contains(point) else { return }
            // 登录 sheet 等自定义关闭路径：先问 presentationController delegate；
            // delegate 拦下（shouldDismiss=false）时由它自己走取消路径并关闭
            //（见 BearyLoginViewController 的 UIAdaptivePresentationControllerDelegate）。
            // shouldDismiss 是 optional 方法：未实现时可选链回 nil、不拦下，直接 dismiss。
            if let pc = sheet.presentationController,
               let delegate = pc.delegate,
               delegate.presentationControllerShouldDismiss?(pc) == false {
                delegate.presentationControllerDidAttemptToDismiss?(pc)
                return
            }
            sheet.dismiss(animated: true)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

// MARK: - 停靠键盘顶升

/// 输入型 sheet 的停靠键盘顶升（只跟停靠键盘，浮动/分屏键盘不动；
/// 判定口径照抄旧键盘跟随 presentation 控制器：帧须与视图相交且触到视图底边）。
/// 拥有方在 viewDidLoad 建一个、强持有；随页释放时自动反注册。
/// 回调给停靠键盘顶边（视图坐标），无停靠键盘时为 nil；回调在键盘动画块内
/// 执行，调用方只改约束常量（按钮组底边／滚动区底边），布局由本类统一推。
final class BearySheetKeyboardAvoidance {

    private weak var view: UIView?
    private let onKeyboardTopChange: (CGFloat?) -> Void
    private var tokens: [NSObjectProtocol] = []

    init(view: UIView, onKeyboardTopChange: @escaping (CGFloat?) -> Void) {
        self.view = view
        self.onKeyboardTopChange = onKeyboardTopChange
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] note in
            self?.keyboardChanged(note)
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            self?.keyboardChanged(note)
        })
        tokens.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] note in
            self?.keyboardHidden(note)
        })
    }

    deinit {
        tokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func keyboardChanged(_ note: Notification) {
        guard let view = view else { return }
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frameInView = view.convert(value.cgRectValue, from: nil)
        let bounds = view.bounds
        guard frameInView.minY < bounds.maxY - 1,
              frameInView.maxY >= bounds.maxY - 1,
              frameInView.intersects(bounds) else {
            // 键盘不再贴底（iPad 悬浮/分屏／已移出屏幕）：顶升清零。
            apply(keyboardTop: nil, note: note)
            return
        }
        apply(keyboardTop: frameInView.minY, note: note)
    }

    private func keyboardHidden(_ note: Notification) {
        apply(keyboardTop: nil, note: note)
    }

    private func apply(keyboardTop: CGFloat?, note: Notification) {
        guard let view = view else { return }
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        if UIAccessibility.isReduceMotionEnabled {
            onKeyboardTopChange(keyboardTop)
            view.layoutIfNeeded()
            return
        }
        UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState]) { [weak self] in
            self?.onKeyboardTopChange(keyboardTop)
            self?.view?.layoutIfNeeded()
        }
    }
}
