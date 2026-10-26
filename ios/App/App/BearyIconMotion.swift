import UIKit

/// 网页图标动效的原生复刻（数值对照 beary.html，颜色一律走 BearyColors）。
/// 减动效时所有动画直接跳到结束态（不动）。
enum BearyIconMotion {

    /// 官方 beary-heart 路径（viewBox 24×24），缩放到目标框。
    /// 路径原文：M12 20s-7.5-4.6-7.5-10.2A4.2 4.2 0 0 1 12 7.4a4.2 4.2 0 0 1 7.5 2.4C19.5 15.4 12 20 12 20z
    /// s 段无前导曲线时控制点 1 = 起点；两段圆弧经端点→圆心换算
    ///（圆心 8.6956/9.9925 与 15.3044/9.9925，半径 4.2，起止角由端点向量算出）。
    static func heartPath(in box: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 12, y: 20))
        path.addCurve(to: CGPoint(x: 4.5, y: 9.8), controlPoint1: CGPoint(x: 12, y: 20), controlPoint2: CGPoint(x: 4.5, y: 15.4))
        path.addArc(withCenter: CGPoint(x: 8.6956, y: 9.9925), radius: 4.2, startAngle: -3.09575, endAngle: -0.66525, clockwise: true)
        path.addArc(withCenter: CGPoint(x: 15.3044, y: 9.9925), radius: 4.2, startAngle: -2.47635, endAngle: -0.04584, clockwise: true)
        path.addCurve(to: CGPoint(x: 12, y: 20), controlPoint1: CGPoint(x: 19.5, y: 15.4), controlPoint2: CGPoint(x: 12, y: 20))
        path.close()
        let scale = box.width / 24
        let transform = CGAffineTransform(translationX: box.minX, y: box.minY).scaledBy(x: scale, y: scale)
        path.apply(transform)
        return path
    }

    /// 点赞描边画出（网页 heartDraw：.5s cubic-bezier(.4,0,.2,1)）。
    /// 返回描边图层，调用方持有并在响应到达时移除；减动效返回 nil（不画）。
    /// 描边色取按钮当前 tint（即图标本身的颜色）：Feed 未赞是墨色、主页未赞是灰色；
    /// 旧代码把灰色写死，在 Feed 上会描出一条与墨色图标不重合的灰心。
    /// 残留修复：图层挂在 imageView 层下、路径用 imageView.bounds 画，
    /// 不再挂按钮层用 imageView.frame 画——frame 会受按压缩放（.84）影响而
    /// 缩小并偏移，按钮重布局后图标移走、旧描边却留在原坐标，右侧露出一截；
    /// 子层则随图标一起缩放与移位，与空心 PNG 始终重合。
    /// fallback 修复：imageView 无框时不再按按钮中心估一个 22 框——按钮带计数标题时
    /// 按钮中心 ≠ 图标中心，估算必偏；先强制布局一次，仍无框说明无图，直接不画。
    /// 动画结束即自清：.5s 画完后底层空心 PNG 本就是同一条轮廓，
    /// 描边层再留着只是重复描边；自清后未点赞态只剩空心 PNG，
    /// 填充与计数仍等服务器确认（语义不动），调用方响应到达时再清一次亦无害。
    static func playHeartStrokeDraw(on button: UIButton) -> CAShapeLayer? {
        if UIAccessibility.isReduceMotionEnabled { return nil }
        guard let imageView = button.imageView else { return nil }
        if imageView.bounds.width <= 0 { button.layoutIfNeeded() }
        guard imageView.bounds.width > 0 else { return nil }
        let host = imageView.layer
        let box = imageView.bounds
        let layer = CAShapeLayer()
        layer.frame = box
        layer.path = heartPath(in: CGRect(origin: .zero, size: box.size)).cgPath
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = button.tintColor.cgColor
        layer.lineWidth = 2 * box.width / 24
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.strokeEnd = 0
        host.addSublayer(layer)
        let anim = CABasicAnimation(keyPath: "strokeEnd")
        anim.fromValue = 0
        anim.toValue = 1
        anim.duration = 0.5
        anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        layer.add(anim, forKey: "bearyHeartDraw")
        layer.strokeEnd = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak layer] in
            layer?.removeFromSuperlayer()
        }
        return layer
    }

    /// 点赞填充淡入（网页 .fill transition fill .3s）。
    /// 网页另有 .25s 延迟（与描边后半段重叠），原生因网络时序已与描边解耦，
    /// 故成功到达时直接淡入 .3s，不再额外延迟。
    static func playFillFade(on button: UIButton) {
        guard let imageView = button.imageView else { return }
        if UIAccessibility.isReduceMotionEnabled { return }
        imageView.alpha = 0
        UIView.animate(withDuration: 0.3, animations: { imageView.alpha = 1 })
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
