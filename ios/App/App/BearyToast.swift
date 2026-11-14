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
/// 展示时长按文案长度分档（U9，见 displayDuration）：≤20 字 2.0s（与旧值一致）、
/// 21–40 字 3.0s、>40 字 4.0s；带动作入口时取字数档与动作档（保底 4.0s）的大值，
/// 无动作提示的时长一字不动；淡入 0.26s、到点淡出 0.26s 后移除；减动效时直接现身、
/// 到点直接移除，不播淡入淡出（与各页原 A5-3 口径一致）。
/// 动作入口（U9）：show 的 actionTitle/action 均可选、默认 nil；两者都传时 toast
/// 右侧显示动作入口、点按先撤 toast 再执行回调；任一缺省即无动作入口，现有
/// 无动作调用点行为与外观完全不变。无动作时容器仍不参与触摸。
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

    static func show(in container: UIView, message: String,
                     actionTitle: String? = nil, action: (() -> Void)? = nil) {
        for oldToast in container.subviews where oldToast is BearyToastView {
            oldToast.removeFromSuperview()
        }
        let toast = BearyToastView(message: message, actionTitle: actionTitle, action: action)
        // r27-10：动作入口是否真实存在（与 BearyToastView 建钮条件一致：
        // actionTitle 与 action 双全才算有动作），决定时长是否取动作保底档。
        let hasAction = actionTitle != nil && action != nil
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
        // 审计 2026-11-02 弹窗组：到点闭包改 [weak toast]——旧强持有会把已被
        // 新 toast 清掉的旧视图再留 2 秒（且到点闭包可能误触已复用的视图层级）；
        // 弱持有下旧视图提前移除后到点闭包为空操作。（阴影/描边不补，属样式 token。）
        if UIAccessibility.isReduceMotionEnabled {
            toast.alpha = 1
            DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration(for: message, hasAction: hasAction)) { [weak toast] in
                toast?.removeFromSuperview()
            }
        } else {
            toast.alpha = 0
            UIView.animate(withDuration: BearyMotion.normal) {
                toast.alpha = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration(for: message, hasAction: hasAction)) { [weak toast] in
                UIView.animate(withDuration: BearyMotion.normal, animations: {
                    toast?.alpha = 0
                }, completion: { _ in
                    toast?.removeFromSuperview()
                })
            }
        }
    }

    /// U9 展示时长分档（按文案字符数，CJK 每字计 1）：短文案沿用旧 2.0s，
    /// 中长文案给足读完时间，长文案再延长一档；r27-10：带动作入口时取字数档
    /// 与动作档（保底 4.0s）的大值——短文案的重试钮也有时间点到；无动作时
    /// 各档数值与旧版逐字一致。fileprivate：发布 pill 的失败态同款分档。
    /// 第十轮：带动作且 VoiceOver 开启时延长到 8.0s——读屏用户需要时间找到、
    /// 聚焦并激活操作钮；8.0s 为动作档 4.0s 的两倍，可调。
    fileprivate static func displayDuration(for message: String, hasAction: Bool = false) -> TimeInterval {
        let base: TimeInterval
        if message.count <= 20 {
            base = 2.0
        } else if message.count <= 40 {
            base = 3.0
        } else {
            base = 4.0
        }
        if hasAction, UIAccessibility.isVoiceOverRunning {
            return 8.0
        }
        return hasAction ? max(base, 4.0) : base
    }

    /// 落点计算：只认“容器页是 Chrome 子页”这一条——模态页的 parent 链
    /// 到不了 Chrome，落 -32；Chrome 子页则读 Chrome 当前 chrome 态。
    /// 未布局（高为 0）或无 window 时回落 -32，不产野值。
    /// fileprivate：发布 pill 与 toast 同落点。
    fileprivate static func bottomConstant(for container: UIView) -> CGFloat {
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

    /// 发布 pill 的底锚（2026-11-14 盖底栏修）：Chrome 底栏/FAB 顶沿的 layout
    /// 锚点；找不到 Chrome 时返回 nil，调用方回落安全区常数。锚点是 layout
    /// 位置，不受藏栏 transform 影响——栏藏起时锚点仍在栏将回到的位置上，
    /// pill 永远悬在栏上方 12pt，不会像旧的一次性常数那样在栏藏起回落 -32
    /// 时落进底栏带里（底栏顶在安全区底之上 64pt，-32 正好盖住它上半截，
    /// 而发布成功后 showPage(.timeline) 又把栏升回 pill 底下）。
    /// fileprivate：发布 pill 与 toast 同文件。
    fileprivate static func publishPillTopAnchor(in container: UIView) -> NSLayoutYAxisAnchor? {
        guard let chrome = chromeViewController(for: container) else { return nil }
        return chrome.publishPillObstructionTopAnchor()
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
/// 改实色 surface3 底；文字仍走 ink（深浅两色下均可读）、字号与内边距不动；
/// 容器不参与触摸（瞬时提示不应吞掉下方内容的点按）。注：2026-10-29 玻璃批
/// 之前是实色 ink 底，本支未恢复 ink 底——动态 ink 在深色下近白，配 ink 文字
/// 会看不清，surface3 是两色下都可读的实色兜底。
private final class BearyToastView: UIView {

    private let label = UILabel()
    /// U9 动作入口：仅 actionTitle 与 action 双全时建钮；无动作时恒 nil，
    /// 视图外观与约束与旧版逐项一致。
    private var actionButton: UIButton?
    private var actionHandler: (() -> Void)?

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
            // 2026-11-05 M5：布局一次落到目标，视觉过渡只用 transform。
            // 先读当前视觉位置（presentation 层含在途动画），再落布局、
            // 由旧位置起播回 0；连续键盘事件每次都从实际视觉位置重算，
            // 中断也不留残余偏移。模型值起播时即为 .identity，播完自然清零。
            // 本体出入场只动 alpha，不与这里的 transform 冲突。
            let hadFrame = frame.height > 0
            let oldVisualY = layer.presentation()?.frame.minY ?? frame.minY
            applyKeyboardAvoidance()
            container.layoutIfNeeded()
            guard hadFrame else { return }
            let dy = oldVisualY - frame.minY
            guard dy != 0 else { return }
            transform = CGAffineTransform(translationX: 0, y: dy)
            let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
            UIView.animate(withDuration: duration, delay: 0,
                           options: [options, .beginFromCurrentState], animations: { [weak self] in
                self?.transform = .identity
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

    init(message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        super.init(frame: .zero)
        backgroundColor = BearyColors.surface3
        // 2026-11-02 定版第 2 组：Toast 补 hairline 阴影（0.08 / 4 / (0, 1)）；
        // 2026-11-07 微明度定版：1px line 描边已随分层改明度阶一并去掉，底改 surface3。
        BearyShadow.applyHairline(to: layer)
        layer.borderWidth = 0
        // U9：有动作入口时容器须接点按（仅钮本身可点）；无动作时保持旧版
        // 不参与触摸，瞬时提示不吞下方内容的点按。
        if let actionTitle = actionTitle, let action = action {
            isUserInteractionEnabled = true
            actionHandler = action
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(actionTitle, for: .normal)
            button.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.setTitleColor(BearyColors.ink, for: .normal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
            actionButton = button
        } else {
            isUserInteractionEnabled = false
        }
        translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .medium))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        if let button = actionButton {
            addSubview(button)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
                label.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -12),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            ])
        }
    }

    /// U9：点动作先撤 toast（到点闭包弱持有旧视图，撤后为空操作，不会
    /// 二次清理），再执行回调；动效只走既有 alpha 淡入淡出，不新增。
    @objc private func actionTapped() {
        removeFromSuperview()
        actionHandler?()
    }

    /// U9：有动作时仅钮区接点按，pill 其余区域继续透传、不吞下方点按；
    /// 无动作时容器本身不参与触摸（isUserInteractionEnabled=false，hit-test
    /// 不到本视图，本分支不生效）。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if let button = actionButton {
            return button.frame.contains(point)
        }
        return false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        // 阴影在 bounds 外：clipsToBounds 会裁掉阴影，故不裁剪；label 内缩 18/10，无溢出。
        clipsToBounds = false
    }
}

// MARK: - 发布后台化底部 pill（Threads Posting/Posted 同款位置）

/// 发布后台化底部 pill：底贴底栏/FAB 顶沿之上 12pt（layout 锚点，见
/// BearyToast.publishPillTopAnchor；栏藏起时锚点不动，pill 永远悬在栏
/// 上方、不盖栏；找不到 Chrome 时回落安全区常数）、同 surface3 底、ink 字、14pt
/// medium、10/18 内边距、半高圆角、hairline 阴影。
/// 结构：文案 label（进行中「正在发布…」）＋ 底部 2pt 进度条（track
/// BearyColors.line、fill ink，内缩 14pt、底边之上 6pt，避开 pill 圆角）；
/// 成功时 fill 走满、对勾 +「已发布」，2.0s 后淡出；失败时文案换调用方传的
/// 现有失败文案、进度条隐去，按文案长度分档（同 BearyToast.displayDuration）
/// 后淡出。isUserInteractionEnabled = false，不吞下方点按；减动效时直现直消、
/// 进度直设终值；VoiceOver 在各态切换时播报文案。
/// 同容器已有 pill 时 show 先移除旧 pill（新任务接管）；视图从容器移除后
/// 全部更新为空操作。键盘不避让：pill 在编辑器退出时才露出，键盘随编辑器
/// 一起收走，落点即无键盘基线。
enum BearyPublishPill {

    static func show(in container: UIView) -> BearyPublishPillView {
        for oldPill in container.subviews where oldPill is BearyPublishPillView {
            oldPill.removeFromSuperview()
        }
        let pill = BearyPublishPillView()
        container.addSubview(pill)
        container.bringSubviewToFront(pill)
        // 2026-11-14 盖底栏修：pill 底贴底栏/FAB 顶沿之上 12pt（layout 锚点，
        // 藏栏 transform 不动锚点，栏回来时 pill 已在它上方、不盖栏）。
        // 旧口径用一次性安全区常数（BearyToast.bottomConstant）：栏藏起时
        // 回落 -32、正好落进底栏带（底栏顶在安全区底之上 64pt），栏一回来
        // 就被盖住，且常数只在 show 时算一次、永不重算。找不到 Chrome
        // 时仍回落旧常数（宿主不是 Chrome 容器时无栏可锚）。
        let bottomConstraint: NSLayoutConstraint
        if let topAnchor = BearyToast.publishPillTopAnchor(in: container) {
            bottomConstraint = pill.bottomAnchor.constraint(equalTo: topAnchor, constant: -12)
        } else {
            bottomConstraint = pill.bottomAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.bottomAnchor,
                constant: BearyToast.bottomConstant(for: container))
        }
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            pill.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            bottomConstraint,
        ])
        UIAccessibility.post(notification: .announcement, argument: "正在发布…")
        if UIAccessibility.isReduceMotionEnabled {
            pill.alpha = 1
        } else {
            pill.alpha = 0
            UIView.animate(withDuration: 0.25) {
                pill.alpha = 1
            }
        }
        return pill
    }
}

/// 发布 pill 视图本体（类型即身份，show 以此识别同容器旧 pill）。
final class BearyPublishPillView: UIView {

    private let label = UILabel()
    private let checkView = UIImageView()
    private let trackView = UIView()
    private let fillView = UIView()
    private var fillWidthConstraint: NSLayoutConstraint?
    private var progress: Double = 0
    private var dismissed = false

    init() {
        super.init(frame: .zero)
        backgroundColor = BearyColors.surface3
        BearyShadow.applyHairline(to: layer)
        layer.borderWidth = 0
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false

        label.text = "正在发布…"
        label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .medium))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.ink
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        checkView.image = BearyIconImages.image(named: "icon_check", pointSize: 15)
        checkView.tintColor = BearyColors.ink
        checkView.isHidden = true
        checkView.translatesAutoresizingMaskIntoConstraints = false

        trackView.backgroundColor = BearyColors.line
        trackView.translatesAutoresizingMaskIntoConstraints = false
        fillView.backgroundColor = BearyColors.ink
        fillView.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [checkView, label])
        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        addSubview(trackView)
        addSubview(fillView)
        let fillWidth = fillView.widthAnchor.constraint(equalToConstant: 0)
        fillWidthConstraint = fillWidth
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            checkView.widthAnchor.constraint(equalToConstant: 15),
            checkView.heightAnchor.constraint(equalToConstant: 15),
            trackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            trackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            trackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            trackView.heightAnchor.constraint(equalToConstant: 2),
            fillView.leadingAnchor.constraint(equalTo: trackView.leadingAnchor),
            fillView.bottomAnchor.constraint(equalTo: trackView.bottomAnchor),
            fillView.heightAnchor.constraint(equalToConstant: 2),
            fillWidth,
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        trackView.layer.cornerRadius = 1
        fillView.layer.cornerRadius = 1
        clipsToBounds = false
        fillWidthConstraint?.constant = trackView.bounds.width * CGFloat(progress)
    }

    /// 进度 0...1：调用方按真实上传字节比喂；animated 只在收尾走满时用，
    /// 上传途中的每次回调都直设（回调本身即动画，不叠加 0.25s 补间）。
    func setProgress(_ value: Double, animated: Bool) {
        guard superview != nil, !dismissed else { return }
        progress = min(max(value, 0), 1)
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.25) {
                self.layoutIfNeeded()
            }
        } else {
            layoutIfNeeded()
        }
    }

    /// 成功：进度走满、对勾 +「已发布」，2.0s 后淡出移除。
    func finishSuccess() {
        guard superview != nil, !dismissed else { return }
        progress = 1
        label.text = "已发布"
        checkView.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: "已发布")
        if UIAccessibility.isReduceMotionEnabled {
            trackView.alpha = 0
            fillView.alpha = 0
            layoutIfNeeded()
        } else {
            UIView.animate(withDuration: 0.25) {
                self.trackView.alpha = 0
                self.fillView.alpha = 0
                self.layoutIfNeeded()
            }
        }
        scheduleDismiss(after: 2.0)
    }

    /// 失败：文案换调用方传的现有失败文案、进度条隐去，按文案长度分档后淡出移除。
    func finishFailure(message: String) {
        guard superview != nil, !dismissed else { return }
        label.text = message
        UIAccessibility.post(notification: .announcement, argument: message)
        if UIAccessibility.isReduceMotionEnabled {
            trackView.alpha = 0
            fillView.alpha = 0
            layoutIfNeeded()
        } else {
            UIView.animate(withDuration: 0.25) {
                self.trackView.alpha = 0
                self.fillView.alpha = 0
                self.layoutIfNeeded()
            }
        }
        scheduleDismiss(after: BearyToast.displayDuration(for: message))
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.dismiss()
        }
    }

    /// 立即淡出移除（新任务接管旧 pill 时调）；重复调用为空操作。
    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        if UIAccessibility.isReduceMotionEnabled {
            removeFromSuperview()
        } else {
            UIView.animate(withDuration: 0.25, animations: {
                self.alpha = 0
            }, completion: { _ in
                self.removeFromSuperview()
            })
        }
    }
}
