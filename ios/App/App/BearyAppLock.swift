import UIKit
import LocalAuthentication

// ===== 冷启动生物识别锁 + 隐私遮罩（2026-10-31 Li 定，均仅 App）=====
// 锁：只冷启动锁一次（回前台不锁）。走系统 LAContext 生物识别——iPhone 面容、
// iPad Air 5 触控指纹同一套代码，绝不写死 Face ID；失败走设备密码兜底
// （.deviceOwnerAuthentication：生物识别或设备密码均可）；取消/失败未通过时
// 一直停在锁屏，没有“跳过”按钮。锁屏与遮罩都是窗口级覆盖层，盖在一切内容
// 之上（包括 veil、modal、游客页），锁屏本身只放官方 logo 与解锁提示，
// 不含任何用户内容（无头像、无数字、无标题、无日记）。
// 遮罩：独立于锁开关（锁关了遮罩照样生效）。切后台时立即显示、回到 active 时
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
    private var lockEvaluating = false
    private var shieldOverlay: UIView?

    private init() {}

    // MARK: - 冷启动锁

    /// 冷启动时调用（SceneDelegate willConnect，建窗后立即调）：开关开着才挂锁屏，
    /// 锁屏在同 runloop 内盖上窗口，首帧渲染前已盖住内容；随后立即发起验证。
    func installColdLockIfNeeded(on window: UIWindow) {
        guard BearyAppLockSettings.isEnabled, lockOverlay == nil else { return }
        isColdLocked = true
        let overlay = makeLockOverlay()
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(overlay)
        window.bringSubviewToFront(overlay)
        lockOverlay = overlay
        evaluateForUnlock()
    }

    private func makeLockOverlay() -> UIView {
        let overlay = UIView()
        overlay.backgroundColor = BearyColors.bg
        // 默认 UIView 即拦截触摸：锁屏在时底下任何按钮都点不到（veil 本身
        // isUserInteractionEnabled=false，若锁屏不拦截，首页按钮会从锁屏下透出）。
        overlay.isUserInteractionEnabled = true
        overlay.accessibilityLabel = "beary 已锁定"

        let logo = UIImageView(image: UIImage(named: "LogoHorizontal"))
        logo.contentMode = .scaleAspectFit
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.accessibilityLabel = "beary"

        let name = BearyAppLockSettings.biometryName
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = BearyColors.ink
        title.textAlignment = .center
        title.text = "使用\(name)解锁"

        let status = UILabel()
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = UIFont.systemFont(ofSize: 13)
        status.textColor = BearyColors.gray
        status.textAlignment = .center
        status.numberOfLines = 0
        status.text = "冷启动验证，仅本次进程需要一次"
        lockStatusLabel = status

        let button = BearyButton(style: .secondaryOutline(.regular))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("解锁", for: .normal)
        button.accessibilityLabel = "解锁"
        button.addTarget(self, action: #selector(lockUnlockButtonTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [logo, title, status, button])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        overlay.addSubview(stack)
        NSLayoutConstraint.activate([
            logo.widthAnchor.constraint(equalToConstant: 79),
            logo.heightAnchor.constraint(equalToConstant: 28),
            button.widthAnchor.constraint(equalToConstant: 220),
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -40),
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
                self.lockStatusLabel?.text = "验证未通过，请再试一次"
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
        UIView.animate(withDuration: 0.25, animations: {
            overlay.alpha = 0
        }) { _ in
            overlay.removeFromSuperview()
        }
        onUnlocked?()
    }

    // MARK: - 隐私遮罩（独立于锁开关）

    /// 切后台时立即显示：只放官方 logo 与纯色底，不含任何用户内容。
    /// 触发点在 sceneWillResignActive（快照拍下之前的最早信号），
    /// sceneDidEnterBackground 再补一次（幂等），确保切换器快照里是遮罩。
    func installShield(on window: UIWindow) {
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
