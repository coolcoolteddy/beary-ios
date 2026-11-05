import UIKit

/// 网页图标动效的原生复刻（数值对照 beary.html，颜色一律走 BearyColors）。
/// 减动效时所有动画直接跳到结束态（不动）。
/// 三层叠加口径（预览 v3 定版）：按压缩放走按钮层（pressDownVisual/pressUp 的
/// button.transform）、pop 走图标层（imageView.layer）、粒子走独立 overlay 层
/// （BearyBurstParticles，挂按钮 superview），三层互不抢 transform。
/// 旧 7 滴按钮 sublayer 粒子层已整删（见 playLikeBurst 注释）；clearLikeBurst 里
/// 按 name 认领的微粒层清理保留为旧轮兜底。
enum BearyIconMotion {

    /// 点赞反馈（ChatGPT 视觉清单已定设计第 1 项，取代 2026-10-27 爆点规格）：
    /// 只保留官方爱心原图的短暂缩放（见 playLikeBurst）；粒子炸开改走
    /// BearyBurstParticles 独立 overlay，不再是按钮 sublayer。
    /// fixall-cell 6-12：清点赞缩放动画残留；按 name 认领的微粒层清理保留为
    /// 无害兜底（旧规格的按钮 sublayer 粒子如有残留仍会被清掉）。
    /// cell 复用时调（prepareForReuse），新一轮反馈开始前也先清。
    static func clearLikeBurst(on button: UIButton) {
        button.imageView?.layer.removeAnimation(forKey: "bearyLikeBurstPop")
        guard let sublayers = button.layer.sublayers else { return }
        for layer in sublayers where layer.name == "bearyLikeBurstDrop" {
            layer.removeFromSuperlayer()
        }
    }

    /// fixall-cell 6-12：清填充淡入残留——移除在途淡入动画并把图标
    /// alpha 复位为 1，防止中途换图/复用时图标停在半透明淡入态。
    static func clearFillFade(on button: UIButton) {
        button.imageView?.layer.removeAnimation(forKey: "bearyFillFade")
        if let imageView = button.imageView, imageView.alpha != 1 {
            imageView.alpha = 1
        }
    }

    /// 点赞反馈只保留官方爱心原图的短暂缩放：1 → 1.15 → 1，.32s。
    /// 只在点赞（填色）的那一刻播，与填色同起（调用方在点按确认时与填色
    /// 一起播，不再等服务端回包）；取消点赞不播。点亮色仍为点赞红
    /// BearyColors.likeRed（#ff3b30）。减动效不播。粒子炸开不在此播，
    /// 由调用方另调 BearyBurstParticles.burstLike（独立 overlay 层）。
    /// 点赞状态、颜色、请求与回滚时机一律不动（调用方原样）。
    static func playLikeBurst(on button: UIButton) {
        guard BearyMotion.animated(true) else { return }
        guard let imageView = button.imageView else { return }
        // 先清上一轮缩放动画残留（快速连点不再多轮堆叠）。
        clearLikeBurst(on: button)
        // 爱心先轻微放大再回弹（1 → 1.15 → 1，.32s）。
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 1.15, 1]
        pop.keyTimes = [0, 0.45, 1]
        pop.duration = 0.32
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        imageView.layer.add(pop, forKey: "bearyLikeBurstPop")
    }

    /// 点赞填充淡入（网页 .fill transition fill .3s）。
    /// 网页另有 .25s 延迟（与描边后半段重叠），原生因网络时序已与描边解耦，
    /// 故成功到达时直接淡入 .3s，不再额外延迟。
    /// fixall-cell 6-12：点赞填充淡入（网页 .fill transition fill .3s）。
    /// 中途换图处理：先按 key 清掉在途淡入（旧图淡入不再与新图叠加），
    /// 再以 keyed CA 淡入从 0 → 1；模型 alpha 全程保持 1，新图不会在
    /// 淡入前以满透明度闪一下，也不会停在半透明态。
    static func playFillFade(on button: UIButton) {
        guard let imageView = button.imageView else { return }
        imageView.layer.removeAnimation(forKey: "bearyFillFade")
        imageView.alpha = 1
        if UIAccessibility.isReduceMotionEnabled { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.3
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        imageView.layer.add(fade, forKey: "bearyFillFade")
    }

    /// 收藏弹一下（视觉清单第 9 项：峰值由 1.3 收到 1.12、时长由 .28s 收到 .16s，
    /// 曲线与回弹终态不变，作用于图标本身）。星星炸开不在此播，由调用方
    /// 另调 BearyBurstParticles.burstStar（独立 overlay 层）。
    static func playBookmarkPop(on button: UIButton) {
        guard let imageView = button.imageView else { return }
        guard BearyMotion.animated(true) else { return }
        imageView.layer.removeAnimation(forKey: "bearyBmPop")
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 1.12, 1]
        pop.keyTimes = [0, 0.4, 1]
        pop.duration = 0.16
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        imageView.layer.add(pop, forKey: "bearyBmPop")
    }

    /// 图标缩放（取消点赞 pre-unlike .8 / 恢复 1；按压已改走按钮层
    /// pressDownVisual/pressUp，不再用本方法；网页 svg transition .13s 同款，
    /// .13s 落在视觉清单第 9 项 0.12–0.18s 档内，不动）。
    static func animateIconScale(on button: UIButton, to scale: CGFloat, duration: TimeInterval = 0.13) {
        guard let imageView = button.imageView else { return }
        let transform = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: scale, y: scale)
        if UIAccessibility.isReduceMotionEnabled {
            imageView.transform = transform
            return
        }
        UIView.animate(withDuration: duration, animations: { imageView.transform = transform })
    }

    /// 通用按压反馈（80 包 W6 全量推广）：按下缩 0.95 + .light 轻震，松手弹簧回 1。
    /// 按压幅度与时长为预览 v3 定版（按下 0.95 / 0.1s、松手 1.03 → 0.99 → 1 / 0.32s）。
    /// 口径（2026-10-28 定）：按压轻震通用，所有挂 bearyAddPressFeedback 的按钮都发；
    /// 点赞/发布/拒绝三处专属反馈（成功/警告）另算，不与按压轻震混淆。
    /// 缩放一律走按钮层（button.transform）：图标层 pop 与粒子 overlay 不受影响，
    /// 三层叠加不抢 transform；行级全宽钮与 imageView 自带旋转的钮不用它，
    /// 改走 haptic-only，见各页接线。
    /// 减动效：缩放直达终值（普通按压）；震动不拿减动效门控
    ///（BearyHaptics 头注释既定口径：两者不是一回事）。
    /// 审计第 30 项：同一次触摸序列仅首次发触感——touchDown 走本方法
    /// （视觉＋轻震），手指滑出后重新滑入走 pressDownVisual（只恢复视觉
    /// 按压态，不再发震）；touchDragEnter 只在已开始的触摸序列内触发，
    /// 故分流即等价于“每序列首次才震”，无需另存序列状态。
    /// 轻震仍走 BearyHaptics.press()（复用缓存的反馈生成器，不现建现扔）；
    /// 成功/警告反馈按实际结果触发（publishSuccess/rejectionWarning），不受此分流影响。
    static func pressDown(on button: UIButton) {
        pressDownVisual(on: button)
        BearyHaptics.press()
    }

    /// 审计第 30 项：重新滑入的视觉恢复——与 pressDown 同款 0.95 缩放、
    /// 同时长同曲线，唯独不发触感。pressDown 复用本方法，视觉行为单点。
    /// 审计 M1：两项动画选项补齐 .allowUserInteraction（回弹窗口内的下一按
    /// 不被吞）与 .beginFromCurrentState（新按压从当前态起播，中断旧回弹）；
    /// 缩放与时长仍是预览 v3 定版，不动。
    static func pressDownVisual(on button: UIButton) {
        let pressed = CGAffineTransform(scaleX: 0.95, y: 0.95)
        guard BearyMotion.animated(true) else {
            button.transform = pressed
            return
        }
        UIView.animate(withDuration: 0.1, delay: 0, options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState], animations: {
            button.transform = pressed
        })
    }

    /// 松手弹簧回 1（预览 v3 定版）：1.03 → 0.99 → 1，0.32s，分段线性。
    /// 减动效关时瞬时回 1（普通按压）。
    /// 审计 M1：同 pressDownVisual，补 .allowUserInteraction 与
    /// .beginFromCurrentState——回弹中途再按不从模型值起跳、不吞下一按。
    static func pressUp(on button: UIButton) {
        guard BearyMotion.animated(true) else {
            button.transform = .identity
            return
        }
        UIView.animateKeyframes(withDuration: 0.32, delay: 0, options: [.calculationModeLinear, .allowUserInteraction, .beginFromCurrentState], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.45) {
                button.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.45, relativeDuration: 0.30) {
                button.transform = CGAffineTransform(scaleX: 0.99, y: 0.99)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.75, relativeDuration: 0.25) {
                button.transform = .identity
            }
        })
    }

    /// 无限旋转（网页 .spin 1s / .official-spin .9s 由调用方传 duration；
    /// 减动效不转，见网页 prefers-reduced-motion 下 .spin{animation:none}）。
    static func startSpin(on view: UIView, duration: TimeInterval, key: String) {
        if UIAccessibility.isReduceMotionEnabled { return }
        view.layer.removeAnimation(forKey: key)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = CGFloat.pi * 2
        spin.duration = duration
        spin.repeatCount = .infinity
        view.layer.add(spin, forKey: key)
    }

    static func stopSpin(on view: UIView, key: String) {
        view.layer.removeAnimation(forKey: key)
    }
}

extension UIButton {
    /// W6：挂通用按压反馈（touchDown 缩+震；松手/滑出/取消回弹）。不改原有
    /// touchUpInside 逻辑与布局；钮自身作 target，不依赖所在 VC 的方法。
    /// 审计 15 项第 12 项：补 touchDragExit（滑出恢复）与 touchDragEnter
    /// （滑入恢复按压态）；业务动作仍只由 touchUpInside 执行；滚动容器
    /// 内滑动时 touchCancel 仍兜底（原有行为不动）。
    /// 审计第 30 项：touchDragEnter 改挂 bearyPressDownVisual——同一次按压
    /// 滑出再滑入只恢复视觉按压态，不重复发轻震；新一次按压的 touchDown
    /// 仍正常发震。
    func bearyAddPressFeedback() {
        addTarget(self, action: #selector(bearyPressDown), for: .touchDown)
        addTarget(self, action: #selector(bearyPressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        addTarget(self, action: #selector(bearyPressDownVisual), for: .touchDragEnter)
    }

    /// W6：行级全宽钮专用——只给按下轻震，不缩放（全宽行缩 .84 会像整行抖动；
    /// 已有底色按压反馈的行也只补震动，不叠加缩放）。
    func bearyAddPressHaptic() {
        addTarget(self, action: #selector(bearyPressDownHapticOnly), for: .touchDown)
    }

    @objc func bearyPressDown() { BearyIconMotion.pressDown(on: self) }
    /// 审计第 30 项：重新滑入只恢复视觉按压态，不发触感。
    @objc func bearyPressDownVisual() { BearyIconMotion.pressDownVisual(on: self) }
    @objc func bearyPressUp() { BearyIconMotion.pressUp(on: self) }
    @objc func bearyPressDownHapticOnly() { BearyHaptics.press() }
}
