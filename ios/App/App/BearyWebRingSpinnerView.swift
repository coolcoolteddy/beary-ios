import UIKit

/// 图片加载转圈（网页同款，不用下拉刷新那套 icon_refresh）。
///
/// 网页口径（beary.html .imgbox::after，图片转圈 v3）：
/// 18pt 圆圈、2pt 描边、底圈走 --line、顶上一段走 --gray、0.8s 线性无限旋转、
/// 居中、不拦截点按、加载失败时隐藏（.img-err::after display:none）。
/// 原生复现：底圈用 line 色整圆，亮弧用 gray 色 90° 圆弧（从顶部起），整层旋转；
/// 减动效时不转（网页 @media reduce 口径：animation:none，圆圈静止）。
/// 灯箱是黑底，用 bright 版：底圈白 30%、亮弧纯白，其余口径不变。
final class BearyWebRingSpinnerView: UIView {

    private let trackLayer = CAShapeLayer()
    private let arcLayer = CAShapeLayer()
    private let bright: Bool
    private var spinning = false

    init(bright: Bool = false) {
        self.bright = bright
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(trackLayer)
        layer.addSublayer(arcLayer)
        trackLayer.fillColor = UIColor.clear.cgColor
        trackLayer.lineWidth = 2
        arcLayer.fillColor = UIColor.clear.cgColor
        arcLayer.lineWidth = 2
        arcLayer.lineCap = .butt
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize { CGSize(width: 18, height: 18) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 1 // 描边 2pt，圆心半径 = (18 - 2) / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        trackLayer.frame = bounds
        trackLayer.path = UIBezierPath(ovalIn: rect).cgPath
        arcLayer.frame = bounds
        // 亮弧：从顶部（-90°）起 90°，对应网页 border-top-color 那一段。
        arcLayer.path = UIBezierPath(
            arcCenter: center,
            radius: rect.width / 2,
            startAngle: -CGFloat.pi / 2,
            endAngle: 0,
            clockwise: true
        ).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    private func updateColors() {
        if bright {
            trackLayer.strokeColor = UIColor(white: 1, alpha: 0.3).cgColor
            arcLayer.strokeColor = UIColor.white.cgColor
        } else {
            trackLayer.strokeColor = BearyColors.line.cgColor
            arcLayer.strokeColor = BearyColors.gray.cgColor
        }
    }

    /// 与 BearyRefreshIconView 同款调用口径：start/stop 即显/藏。
    func startSpinning() {
        guard !spinning else { return }
        spinning = true
        isHidden = false
        alpha = 1
        layer.removeAnimation(forKey: "web-ring-spin")
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue = Double.pi * 2
        anim.duration = 0.8
        anim.repeatCount = .infinity
        layer.add(anim, forKey: "web-ring-spin")
    }

    func stopSpinning() {
        spinning = false
        layer.removeAnimation(forKey: "web-ring-spin")
        isHidden = true
    }
}
