import UIKit

/// 统一轻提示：此前 10 处 toast 各写一套（圆角 20/16/12、内边距
/// 8/16、9/16、10/14、12/16、时长 1.6/2.0/2.2 分裂，且 10 处 bottom 全是
/// -158、含无 FAB 的页），B 批收敛为一处；2026-10-29 玻璃批再改两处：
/// 落点不再由调用方传参决定（调用点各猜一次，猜错即被底栏挡住——
/// 我的页／消息页有底栏无 FAB，旧 -32 正压在底栏上），改由组件按当前页
/// 实际可见的底部 chrome 计算；样式由实色 ink 底换成官方液态玻璃 pill
/// （与顶栏／底栏同款 BearyGlass 中性 tint），文字走 ink。
///
/// 统一样式：玻璃 pill、ink 字、14pt medium、内边距 top 10 / left 18 /
/// bottom 10 / right 18、两侧留 20pt 上限、居中；pill 圆角取半高
/// （layoutSubviews 跟 bounds 走，单行约 19pt，与“圆角 18”同口径）。
/// 展示 2.0s：淡入 0.25s、到点淡出 0.25s 后移除；减动效时直接现身、
/// 到点直接移除，不播淡入淡出（与各页原 A5-3 口径一致）。
/// 落点：容器页是 Chrome 子页时，按 Chrome 当前可见的底部 chrome 定——
/// FAB 可见落 FAB 顶之上 12pt（FAB 底边安全区 -92、高 54、顶为 -146，
/// 故与旧 -158 同值），仅底栏可见落底栏顶之上 12pt（底栏底边安全区 -6、
/// 高 58、顶为 -64，故为 -76）；两者皆无或容器不在 Chrome 子页内
/// （全屏模态等盖住 Chrome 的页）落安全区 -32pt。
/// 键盘避让（审计第 10 项）：上述落点只是无键盘时的基线；键盘升起时
/// 若键盘顶边高于该基线对应的遮挡边界，toast 改落键盘顶之上 12pt，
/// 取两者中更高的遮挡边界（min），键盘收起后落回基线。基线在 show 时
/// 冻结（与旧行为一致，显示期内底栏/FAB 变化不重算）；键盘位置在
/// 显示期内随键盘通知实时跟随，与键盘同速同曲线移动。编辑器自身的
/// keyboardWillShow/Hide 处理不动，本文件只读键盘通知、不改编辑器。
/// 新 toast 先清同容器旧 toast：草稿箱 G7“新 toast 先清旧 toast”
/// 原语义由此处统一承接，其余页旧实现的多例叠加/计时互踩一并收敛；
/// 旧 toast 挂起的到点闭包只持有旧视图，移除后为空操作，不会误清新 toast。
enum BearyToast {

    static func show(in container: UIView, message: String) {
        for oldToast in container.subviews where oldToast is BearyToastView {
            oldToast.removeFromSuperview()
        }
        let toast = BearyToastView(message: message)
        container.addSubview(toast)
        container.bringSubviewToFront(toast)
        let bottomConstraint = toast.bottomAnchor.constraint(
            equalTo: container.safeAreaLayoutGuide.bottomAnchor,
            constant: bottomConstant(for: container))
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            bottomConstraint,
        ])
        // 键盘避让接线：基线即上面刚算出的 constant，键盘态由此处起跟随。
        toast.bindKeyboardAvoidance(bottomConstraint: bottomConstraint, container: container)
        // 8-8：VoiceOver 播报——toast 仅为普通 UIView + UILabel 时 VoiceOver
        // 用户可能错过反馈，显示时同步发 announcement（减动效与否同播）。
        UIAccessibility.post(notification: .announcement, argument: message)
        if UIAccessibility.isReduceMotionEnabled {
            toast.alpha = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                toast.removeFromSuperview()
            }
        } else {
            toast.alpha = 0
            UIView.animate(withDuration: 0.25) {
                toast.alpha = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                UIView.animate(withDuration: 0.25, animations: {
                    toast.alpha = 0
                }, completion: { _ in
                    toast.removeFromSuperview()
                })
            }
        }
    }

    /// 落点计算：只认“容器页是 Chrome 子页”这一条——模态页的 parent 链
    /// 到不了 Chrome，落 -32；Chrome 子页则读 Chrome 当前 chrome 态。
    /// 未布局（高为 0）或无 window 时回落 -32，不产野值。
    private static func bottomConstant(for container: UIView) -> CGFloat {
        let fallback: CGFloat = -32
        guard container.bounds.height > 0, container.window != nil,
              let chrome = chromeViewController(for: container),
              let top = chrome.toastObstructionTop(in: container) else {
            return fallback
        }
        let safeBottomY = container.bounds.height - container.safeAreaInsets.bottom
        let constant = top - 12 - safeBottomY
        return constant < 0 ? constant : fallback
    }

    /// 响应链找容器所属 VC（子视图→父视图→根视图→VC）。
    private static func viewController(for view: UIView) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let vc = current as? UIViewController { return vc }
            responder = current.next
        }
        return nil
    }

    /// parent 链上找 Chrome：子页（addChild 挂进 Chrome 的页、Chrome 自身）
    /// 能找到；模态页（present 出来的，parent 为 nil）找不到，回落 -32。
    private static func chromeViewController(for container: UIView) -> BearyChromeViewController? {
        var vc = viewController(for: container)
        while let current = vc {
            if let chrome = current as? BearyChromeViewController { return chrome }
            vc = current.parent
        }
        return nil
    }
}

/// 统一 toast 视图本体：类型即身份（show 先清同容器旧 toast 时以此识别，
/// 不占 tag、不与 Feed 的 991/992 号 tag 冲突）。
/// 视觉清单第 12 项：玻璃已撤（玻璃范围 Token 只允许栏/菜单，Toast 不在内），
/// 改实色 surface 底；文字仍走 ink（深浅两色下均可读）、字号与内边距不动；
/// 容器不参与触摸（瞬时提示不应吞掉下方内容的点按）。注：2026-10-29 玻璃批
/// 之前是实色 ink 底，本支未恢复 ink 底——动态 ink 在深色下近白，配 ink 文字
/// 会看不清，surface 是两色下都可读的实色兜底。
private final class BearyToastView: UIView {

    private let label = UILabel()

    // MARK: - 键盘避让（审计第 10 项）

    /// show 时冻结的无键盘基线（底栏/FAB/-32 回落，见 BearyToast 注释）；
    /// 显示期内只动键盘这一项，不重算基线，其他触发点行为与旧版一致。
    private var baseBottomConstant: CGFloat = -32
    private weak var toastContainer: UIView?
    private var bottomConstraint: NSLayoutConstraint?
    /// 键盘在 container 坐标系中的顶边；nil = 无贴底键盘（未弹出、
    /// 已收起、或悬浮/分体等不贴底边、不盖住底部 toast 的形态）。
    private var keyboardTopInContainer: CGFloat?

    /// 接线：存基线与底部约束，读一次键盘当前态（键盘可能在 toast
    /// 出现前就已升起——通知不会重播，故不能只等通知；keyboardLayoutGuide
    /// 的 layoutFrame 在键盘已升起时即为当前键盘帧，补上这一拍），
    /// 随后用键盘通知跟随位置变化。deinit 时注销，不留野观察者。
    func bindKeyboardAvoidance(bottomConstraint: NSLayoutConstraint, container: UIView) {
        baseBottomConstant = bottomConstraint.constant
        self.bottomConstraint = bottomConstraint
        toastContainer = container
        let guideFrame = container.keyboardLayoutGuide.layoutFrame
        keyboardTopInContainer = guideFrame.height > 0 ? guideFrame.minY : nil
        applyKeyboardAvoidance()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(keyboardDidChange(_:)),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidChange(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardDidChange(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func keyboardDidChange(_ notification: Notification) {
        guard let container = toastContainer, superview != nil else { return }
        if notification.name == UIResponder.keyboardWillHideNotification {
            keyboardTopInContainer = nil
        } else if let frameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue {
            // 与编辑器 applyKeyboard 同口径：from: nil 即按 window 坐标换算。
            let inContainer = container.convert(frameValue.cgRectValue, from: nil)
            let bounds = container.bounds
            // 只认贴底键盘：帧须与容器相交且触到容器底边；悬浮键盘
            // （帧悬在半空、不触底边）不盖底部 toast，不应把 toast 顶上去。
            // 收起途中的 WillChangeFrame 终帧在屏外（minY 已过底边），同判为无。
            if inContainer.minY < bounds.maxY - 1, inContainer.maxY >= bounds.maxY - 1,
               inContainer.intersects(bounds) {
                keyboardTopInContainer = inContainer.minY
            } else {
                keyboardTopInContainer = nil
            }
        }
        var duration: TimeInterval = 0.25
        var curveRaw: UInt = 0
        if let userInfo = notification.userInfo {
            if let d = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
                duration = d
            }
            if let c = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber {
                curveRaw = c.uintValue
            }
        }
        if UIAccessibility.isReduceMotionEnabled {
            applyKeyboardAvoidance()
            container.layoutIfNeeded()
        } else {
            let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
            UIView.animate(withDuration: duration, delay: 0,
                           options: [options, .beginFromCurrentState], animations: { [weak self] in
                self?.applyKeyboardAvoidance()
                container.layoutIfNeeded()
            })
        }
    }

    /// 落点 = min(基线, 键盘顶之上 12pt)：键盘顶更高（Y 更小）时取键盘，
    /// 否则维持基线；无键盘时恒为基线，与旧版逐像素一致。
    /// 仅改 constant，不触布局本身；初次调用时只设值、不强制布局，
    /// 由系统下一布局拍统一生效。
    private func applyKeyboardAvoidance() {
        guard let container = toastContainer, let constraint = bottomConstraint else { return }
        var constant = baseBottomConstant
        if let top = keyboardTopInContainer {
            let safeBottomY = container.bounds.height - container.safeAreaInsets.bottom
            constant = min(constant, top - 12 - safeBottomY)
        }
        constraint.constant = constant
    }

    init(message: String) {
        super.init(frame: .zero)
        backgroundColor = BearyColors.surface
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = BearyColors.ink
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        clipsToBounds = true
    }
}
