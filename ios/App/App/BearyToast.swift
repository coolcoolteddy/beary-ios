import UIKit

/// B 批统一轻提示：此前 10 处 toast 各写一套（圆角 20/16/12、内边距
/// 8/16、9/16、10/14、12/16、时长 1.6/2.0/2.2 分裂，且 10 处 bottom 全是
/// -158、含无 FAB 的页），本组件收敛为一处。Feed/Profile 现已广泛调用
/// 本组件（Feed 8 处、Profile 9 处），落点由调用方 aboveFAB 决定；
/// 旧“Feed/Profile 的 toast 不在此改”表述已过期，2026-10-28 全修批删改。
///
/// 统一样式：ink 底、bg 字、14pt medium、内边距 top 10 / left 18 /
/// bottom 10 / right 18、两侧留 20pt 上限、居中；胶囊圆角取半高
/// （layoutSubviews 跟 bounds 走，单行约 19pt，与“圆角 18”同口径）。
/// 展示 2.0s：淡入 0.25s、到点淡出 0.25s 后移除；减动效时直接现身、
/// 到点直接移除，不播淡入淡出（与各页原 A5-3 口径一致）。
/// 落点：aboveFAB=true 时 bottom = 安全区 -158pt（FAB 顶之上 12pt，
/// FAB 底边安全区 -92、高 54、顶为 -146）；aboveFAB=false 时
/// bottom = 安全区 -32pt（无 FAB 的页不再悬空）。
/// 新 toast 先清同容器旧 toast：草稿箱 G7“新 toast 先清旧 toast”
/// 原语义由此处统一承接，其余页旧实现的多例叠加/计时互踩一并收敛；
/// 旧 toast 挂起的到点闭包只持有旧视图，移除后为空操作，不会误清新 toast。
enum BearyToast {

    static func show(in container: UIView, message: String, aboveFAB: Bool) {
        for oldToast in container.subviews where oldToast is BearyToastView {
            oldToast.removeFromSuperview()
        }
        let toast = BearyToastView(message: message)
        container.addSubview(toast)
        container.bringSubviewToFront(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            toast.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            toast.bottomAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.bottomAnchor,
                constant: aboveFAB ? -158 : -32),
        ])
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
}

/// 统一 toast 视图本体：类型即身份（show 先清同容器旧 toast 时以此识别，
/// 不占 tag、不与 Feed 的 991/992 号 tag 冲突）。
private final class BearyToastView: UIView {

    private let label = UILabel()

    init(message: String) {
        super.init(frame: .zero)
        backgroundColor = BearyColors.ink
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.font = UIFont.systemFont(ofSize: 14, weight: .medium)
        label.textColor = BearyColors.bg
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
    }
}
