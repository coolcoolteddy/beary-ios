import UIKit
import LocalAuthentication

// ===== 冷启动生物识别锁 + 隐私遮罩（2026-10-31 Li 定，均仅 App）=====
// 锁：只冷启动锁一次（回前台不锁）。走系统 LAContext 生物识别——iPhone 面容、
// iPad Air 5 触控指纹同一套代码，绝不写死 Face ID；失败走设备密码兜底
// （.deviceOwnerAuthentication：生物识别或设备密码均可）；取消/失败未通过时
// 一直停在锁屏，没有“跳过”按钮。锁屏与遮罩都是窗口级覆盖层，盖在一切内容
// 之上（包括 veil、modal、游客页），锁屏本身只放官方 logo 与解锁提示，
// 不含任何用户内容（无头像、无数字、无标题、无日记）。
// 遮罩：独立于锁开关（锁关了遮罩照样生效），但另有独立开关（默认开；
// 关了切后台不显示遮罩）。切后台时立即显示、回到 active 时
// 无验证直接撤掉——只防切换器快照偷看，不改变“回前台不锁”的口径。
// 开关默认关：用户在设置页“账号与安全”手动开启后，下一次冷启动才锁；
// 开启/关闭操作本身都要先验一次生物识别（防已解锁手机被他人随手关掉）。
// 后端、网页端一字不动；生物识别数据不出设备（系统自己管）。

enum BearyAppLockSettings {
    static let defaultsKey = "beary_biometric_lock_enabled"

    /// 开关值（默认关）。只读走 UserDefaults，写走 setEnabled（设置页已验身份后才调）。
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: defaultsKey)
    }

    // 隐私遮罩开关（2026-11-04 Li 定，独立于锁开关）：默认开；
    // 关了切后台不再显示遮罩。只读走 UserDefaults，写走 setMaskEnabled。
    static let maskDefaultsKey = "beary_privacy_mask_enabled"

    static var isMaskEnabled: Bool {
        UserDefaults.standard.object(forKey: maskDefaultsKey) as? Bool ?? true
    }

    static func setMaskEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: maskDefaultsKey)
    }

    /// 当前设备的生物识别名：面容识别 / 触控 ID / Optic ID；无生物识别时回落“生物识别”。
    /// 文案一律由此出，iPad 上绝不写成仅面容。
    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "面容识别"
        case .touchID: return "触控 ID"
        case .opticID: return "Optic ID"
        default: return "生物识别"
        }
    }

    /// 开关是否可开：只有设备已录入生物识别才可开。未录入时设置页置灰并给原因，不硬开。
    static var availability: (available: Bool, reason: String?) {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return (true, nil)
        }
        let reason: String
        switch error?.code {
        case LAError.biometryNotEnrolled.rawValue:
            reason = "设备未录入\(biometryName)，请先在系统设置中录入"
        case LAError.biometryNotAvailable.rawValue:
            reason = "此设备不支持生物识别"
        case LAError.passcodeNotSet.rawValue:
            reason = "设备未设置密码，请先在系统设置中设置密码"
        default:
            reason = "此设备暂无法使用生物识别"
        }
        return (false, reason)
    }

    /// 通用验证入口（设置页开关操作复用）：生物识别或设备密码均可，取消/失败返回 false。
    static func evaluate(reason: String, completion: @escaping (Bool) -> Void) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async { completion(success) }
        }
    }
}

final class BearyAppLockManager {
    static let shared = BearyAppLockManager()

    /// 本次进程是否正处冷启动锁中（解锁成功后即 false，本进程内不再重锁）。
    private(set) var isColdLocked = false
    /// 冷启动解锁完成后的回调（容器接：补跑被推迟的 veil 起播）。
    var onUnlocked: (() -> Void)?

    private var lockOverlay: UIView?
    private var lockStatusLabel: UILabel?
    private var lockUnlockButton: UIButton?
    /// 锁屏出现前 VoiceOver 的焦点元素（通常为冷启动前最后聚焦处；冷启动时常为 nil）。
    /// weak 持有：原元素失效即放弃返回，不强留。取焦点 API 与通知弹层同款 iOS 17 守门。
    private weak var lockPreviousFocusedElement: AnyObject?
    private var lockEvaluating = false
    private var shieldOverlay: UIView?

    private init() {}

    // MARK: - 冷启动锁

    /// 冷启动时调用（SceneDelegate willConnect，建窗后立即调）：开关开着才挂锁屏，
    /// 锁屏在同 runloop 内盖上窗口，首帧渲染前已盖住内容；随后立即发起验证。
    func installColdLockIfNeeded(on window: UIWindow) {
        guard BearyAppLockSettings.isEnabled, lockOverlay == nil else { return }
        // 锁屏出现前先记焦点：覆盖层加进层级后当前焦点即被锁屏夺走，此时再记就晚了
        //（与通知弹层 show 时记 previousFocusedElement 同款做法）。
        if #available(iOS 17.0, *) {
            lockPreviousFocusedElement = UIAccessibility.focusedElement(using: nil) as? AnyObject
        }
        isColdLocked = true
        let overlay = makeLockOverlay()
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(overlay)
        window.bringSubviewToFront(overlay)
        lockOverlay = overlay
        // VoiceOver：锁屏出现即聚焦“解锁”。下一 runloop 再发，等布局落位；
        // 若期间已解锁（lockOverlay 已置 nil）则不发。未开 VoiceOver 时 post 为空操作。
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.lockOverlay?.superview != nil,
                  let button = self.lockUnlockButton else { return }
            UIAccessibility.post(notification: .screenChanged, argument: button)
        }
        evaluateForUnlock()
    }

    private func makeLockOverlay() -> UIView {
        let overlay = UIView()
        overlay.backgroundColor = BearyColors.bg
        // 默认 UIView 即拦截触摸：锁屏在时底下任何按钮都点不到（veil 本身
        // isUserInteractionEnabled=false，若锁屏不拦截，首页按钮会从锁屏下透出）。
        overlay.isUserInteractionEnabled = true
        // VoiceOver：锁屏为普通叠加层、非 VC，须显式声明模态，焦点才不越过
        // 覆盖层浏览到底下的内容（与通知弹层 overlayView 同款声明）。
        overlay.accessibilityViewIsModal = true
        overlay.accessibilityLabel = "beary 已锁定"

        let logo = UIImageView(image: UIImage(named: "LogoHorizontal"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.accessibilityLabel = "beary"

        let name = BearyAppLockSettings.biometryName
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        // 审计-个人页设置：锁屏字号改 scaledFont（旧 15/13 写死，不跟系统字号）。
        title.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        title.adjustsFontForContentSizeCategory = true
        title.textColor = BearyColors.ink
        title.textAlignment = .center
        title.text = "使用\(name)解锁"

        let status = UILabel()
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        status.adjustsFontForContentSizeCategory = true
        status.textColor = BearyColors.gray
        status.textAlignment = .center
        status.numberOfLines = 0
        status.text = "重新启动 beary 时验证一次，短暂切换到其他应用后返回不会重复验证"
        lockStatusLabel = status

        let button = BearyButton(style: .secondaryOutline(.regular))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("解锁", for: .normal)
        button.accessibilityLabel = "解锁"
        button.addTarget(self, action: #selector(lockUnlockButtonTapped), for: .touchUpInside)
        lockUnlockButton = button

        let stack = UIStackView(arrangedSubviews: [logo, title, status, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        // 锁屏安全区滚动：内容改放安全区内的滚动列。空间足够时内容区与滚动视口
        // 等高、栈在内容区内居中（与旧居中布局同观感）；空间不足（横屏、窄窗口/
        // 分屏、最大字号加验证失败长文案）时内容区随栈长高、超出视口部分可滚动，
        // 解锁按钮始终可滚到，不再被居中布局上下同溢推出可见区。
        // 圆角/间距/颜色/字号一律不动：栈间距 16、左右 40、logo 79×28、按钮宽 220 均沿用旧值。
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        // 750 优先级：栈高超内容区时上下贴边约束（必需）先胜出、内容区随栈长高；
        // 栈矮时内容区由“不低于视口高”撑满，居中约束生效、栈居中。
        // 同优先级的“内容区高 = 栈高”把内容区高度钉在最小可行值（视口高与栈高取大），
        // 避免仅用 ≥ 约束时内容区高度欠定。
        let stackCenterY = stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        stackCenterY.priority = .defaultHigh
        let contentHeightFitsStack = contentView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        contentHeightFitsStack.priority = .defaultHigh
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 79),
            logo.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(equalToConstant: 220),
            scrollView.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
            contentHeightFitsStack,
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stackCenterY,
            stack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -40),
        ])
        return overlay
    }

    @objc private func lockUnlockButtonTapped() {
        evaluateForUnlock()
    }

    private func evaluateForUnlock() {
        guard !lockEvaluating else { return }
        lockEvaluating = true
        let name = BearyAppLockSettings.biometryName
        BearyAppLockSettings.evaluate(reason: "使用\(name)解锁 beary") { [weak self] success in
            guard let self = self else { return }
            self.lockEvaluating = false
            if success {
                self.unlock()
            } else {
                // 取消/失败都停在锁屏：不撤覆盖层、不放内容；只把提示换成可重试的文案。
                // （系统密码兜底已在 evaluatePolicy 内：生物识别失败后用户可选设备密码，
                // 只有最终仍未通过才走到这里。）
                // 审计-个人页设置：失败文案补设备密码入口（旧文案只说再试一次，
                // 未提示点“解锁”可改走设备密码）。
                self.lockStatusLabel?.text = "验证未通过，请再试一次，也可用设备密码解锁"
            }
        }
    }

    private func unlock() {
        guard let overlay = lockOverlay else {
            isColdLocked = false
            return
        }
        isColdLocked = false
        lockOverlay = nil
        lockStatusLabel = nil
        lockUnlockButton = nil
        let previousFocusedElement = lockPreviousFocusedElement
        lockPreviousFocusedElement = nil
        // VoiceOver 焦点恢复：覆盖层移除后，把焦点还给锁屏出现前记下的元素；
        // 冷启动时无原焦点（记下的是 nil）则发 screenChanged、由系统落到新页首个元素。
        // 未开 VoiceOver 时 post 为空操作。恢复挂在移除完成点，不在淡出动画中途抢焦点。
        let restoreVoiceOverFocus = {
            if let element = previousFocusedElement {
                UIAccessibility.post(notification: .layoutChanged, argument: element)
            } else {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
        // 审计动效组：锁屏解锁补减动效分支——减动效时直出终值，不播 0.25s 淡出。
        if UIAccessibility.isReduceMotionEnabled {
            overlay.alpha = 0
            overlay.removeFromSuperview()
            restoreVoiceOverFocus()
        } else {
            UIView.animate(withDuration: 0.25, animations: {
                overlay.alpha = 0
            }) { _ in
                overlay.removeFromSuperview()
                restoreVoiceOverFocus()
            }
        }
        // 审计-个人页设置：onUnlocked 调完置 nil。复核结论：容器接线确为
        // [weak chrome] 捕获（SceneDelegate），本处置 nil 属纵深防御——
        // 防 unlock 被重复触发时回调重跑（veil 起播只应跑一次）。
        let callback = onUnlocked
        onUnlocked = nil
        callback?()
    }

    // MARK: - 隐私遮罩（独立于锁开关）

    /// 切后台时立即显示：只放官方 logo 与纯色底，不含任何用户内容。
    /// 触发点在 sceneWillResignActive（快照拍下之前的最早信号），
    /// sceneDidEnterBackground 再补一次（幂等），确保切换器快照里是遮罩。
    func installShield(on window: UIWindow) {
        // 2026-11-04 隐私遮罩开关：关了不显示遮罩（默认开，保持现行行为）。
        guard BearyAppLockSettings.isMaskEnabled else { return }
        if let existing = shieldOverlay {
            if existing.window === window {
                window.bringSubviewToFront(existing)
                return
            }
            // 残留引用：旧遮罩已不在本窗口层级里（层级重建等）——丢掉重建，
            // 避免“引用非空、屏上无遮罩、新遮罩又建不出来”的 stale 态。
            existing.removeFromSuperview()
            shieldOverlay = nil
        }
        let shield = UIView()
        shield.backgroundColor = BearyColors.bg
        shield.isUserInteractionEnabled = true
        let logo = UIImageView(image: UIImage(named: "LogoHorizontal"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.accessibilityLabel = "beary"
        shield.addSubview(logo)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 79),
            logo.heightAnchor.constraint(equalToConstant: 28),
            logo.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
            logo.centerYAnchor.constraint(equalTo: shield.centerYAnchor),
        ])
        shield.frame = window.bounds
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(shield)
        window.bringSubviewToFront(shield)
        shieldOverlay = shield
    }

    /// 回前台时无验证直接撤掉（回前台不锁的口径不变；遮罩只防切换器偷看）。
    /// 撤掉挂在两个点：sceneWillEnterForeground（真进后台再回来）与
    /// sceneDidBecomeActive（下拉通知中心/控制中心、切换器点回本卡等只走
    /// resignActive → becomeActive、根本不进后台的路）；后者缺了就会卡遮罩。
    func removeShield() {
        shieldOverlay?.removeFromSuperview()
        shieldOverlay = nil
    }
}
