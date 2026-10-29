import UIKit

/// 网页图标动效的原生复刻（数值对照 beary.html，颜色一律走 BearyColors）。
/// 减动效时所有动画直接跳到结束态（不动）。
enum BearyIconMotion {

    /// 点赞成功爆点（Li 2026-10-27 新规格，替代描边画出）：爱心轻微放大再回弹，
    /// 同时向外炸出 7 滴红色液体微粒（20–30pt 后淡出）。只在点赞（填色）的那一刻播，
    /// 与填色同起（调用方在点按确认时与填色一起播，不再等服务端回包）；
    /// 取消点赞不炸。点亮色为点赞红 BearyColors.likeRed（#ff3b30）。减动效不播。
    /// fixall-cell 6-12：清点赞爆点残留——按钮层上本轮/旧轮的微粒层
    /// （按 name 认领）与爆点缩放动画。cell 复用时调（prepareForReuse），
    /// 新一轮爆点开始前也先清，防止 0.55s 窗口内复用串位或多轮堆叠。
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

    static func playLikeBurst(on button: UIButton) {
        if UIAccessibility.isReduceMotionEnabled { return }
        guard let imageView = button.imageView else { return }
        // 先清上一轮残留微粒（快速连点/复用窗口内旧滴不再堆叠串位）。
        clearLikeBurst(on: button)
        // 爱心先轻微放大再回弹（1 → 1.22 → 1，.32s）。
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 1.22, 1]
        pop.keyTimes = [0, 0.45, 1]
        pop.duration = 0.32
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        imageView.layer.add(pop, forKey: "bearyLikeBurstPop")
        // 7 滴液体：定角放射（全向），橙色系交替，飞 22–30pt 后淡出缩没。
        let center = imageView.center
        let angles: [CGFloat] = [-90, -38, 14, 66, 118, 170, -142]
        let distances: [CGFloat] = [28, 23, 30, 24, 29, 22, 26]
        let sizes: [CGFloat] = [5, 4, 5.5, 4.5, 5, 4, 5.5]
        for i in 0..<7 {
            let rad = angles[i] * .pi / 180
            let size = sizes[i]
            let dot = CALayer()
            dot.name = "bearyLikeBurstDrop"
            dot.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            dot.cornerRadius = size / 2
            dot.backgroundColor = (i % 2 == 0 ? BearyColors.likeRed : BearyColors.alpha(BearyColors.likeRed, 0.6)).cgColor
            button.layer.addSublayer(dot)
            let target = CGPoint(x: center.x + cos(rad) * distances[i], y: center.y + sin(rad) * distances[i])
            let group = CAAnimationGroup()
            group.duration = 0.5
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            group.fillMode = .forwards
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(cgPoint: dot.position)
            move.toValue = NSValue(cgPoint: target)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1
            shrink.toValue = 0.5
            group.animations = [move, fade, shrink]
            dot.add(group, forKey: "bearyLikeBurstDrop")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak dot] in
                dot?.removeFromSuperlayer()
            }
        }
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

    /// 收藏弹一下（网页 bmPop：.28s ease，scale 1→1.3→1，作用于图标本身）。
    static func playBookmarkPop(on button: UIButton) {
        guard let imageView = button.imageView else { return }
        if UIAccessibility.isReduceMotionEnabled { return }
        imageView.layer.removeAnimation(forKey: "bearyBmPop")
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1, 1.3, 1]
        pop.keyTimes = [0, 0.4, 1]
        pop.duration = 0.28
        pop.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1)
        imageView.layer.add(pop, forKey: "bearyBmPop")
    }

    /// 图标缩放（按压 .84 / 取消点赞 pre-unlike .8 / 恢复 1，网页 svg transition .13s 同款）。
    static func animateIconScale(on button: UIButton, to scale: CGFloat, duration: TimeInterval = 0.13) {
        guard let imageView = button.imageView else { return }
        let transform = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: scale, y: scale)
        if UIAccessibility.isReduceMotionEnabled {
            imageView.transform = transform
            return
        }
        UIView.animate(withDuration: duration, animations: { imageView.transform = transform })
    }

    /// 通用按压反馈（80 包 W6 全量推广）：按下缩 .84 + .light 轻震，松手回 1。
    /// 口径（2026-10-28 定）：按压轻震通用，所有挂 bearyAddPressFeedback 的按钮都发；
    /// 点赞/发布/拒绝三处专属反馈（成功/警告）另算，不与按压轻震混淆。
    /// 有图缩 imageView（iconTouchDown 同款）；无图缩整颗（行级全宽钮与
    /// imageView 自带旋转的钮不用它，改走 haptic-only，见各页接线）。
    /// 减动效：缩放直达终值（animateIconScale 同口径）；震动不拿减动效门控
    ///（BearyHaptics 头注释既定口径：两者不是一回事）。
    static func pressDown(on button: UIButton) {
        if button.imageView != nil {
            animateIconScale(on: button, to: 0.84)
        } else {
            scaleButton(button, to: 0.84)
        }
        BearyHaptics.press()
    }

    static func pressUp(on button: UIButton) {
        if button.imageView != nil {
            animateIconScale(on: button, to: 1)
        } else {
            scaleButton(button, to: 1)
        }
    }

    private static func scaleButton(_ button: UIButton, to scale: CGFloat) {
        let transform = scale == 1 ? CGAffineTransform.identity : CGAffineTransform(scaleX: scale, y: scale)
        if UIAccessibility.isReduceMotionEnabled {
            button.transform = transform
            return
        }
        UIView.animate(withDuration: 0.13, animations: { button.transform = transform })
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
    func bearyAddPressFeedback() {
        addTarget(self, action: #selector(bearyPressDown), for: .touchDown)
        addTarget(self, action: #selector(bearyPressUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    /// W6：行级全宽钮专用——只给按下轻震，不缩放（全宽行缩 .84 会像整行抖动；
    /// 已有底色按压反馈的行也只补震动，不叠加缩放）。
    func bearyAddPressHaptic() {
        addTarget(self, action: #selector(bearyPressDownHapticOnly), for: .touchDown)
    }

    @objc func bearyPressDown() { BearyIconMotion.pressDown(on: self) }
    @objc func bearyPressUp() { BearyIconMotion.pressUp(on: self) }
    @objc func bearyPressDownHapticOnly() { BearyHaptics.press() }
}
