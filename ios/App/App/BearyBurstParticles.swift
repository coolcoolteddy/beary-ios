import UIKit

/// 粒子炸开的独立 overlay 层：透明、不接手势、锚在触发按钮上。
/// 粒子飞完自清；取消点赞／复用时由 BearyBurstParticles.clear(from:) 清掉。
/// 与按压层（按钮 transform）与图标层（imageView.layer 的 pop）互不干扰：
/// overlay 挂在按钮的 superview 上、按按钮 center 定位，按钮缩放不影响粒子。
final class BearyBurstOverlayView: UIView {
    weak var anchorButton: UIButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 点赞液体炸开／收藏炸星星的共用粒子 helper（卡片与详情共用，不各写一份）。
/// 预览 v3 定版参数；无涟漪圈；只走 transform / opacity；减动效门控走 BearyMotion。
enum BearyBurstParticles {

    private struct Style {
        let colors: [UIColor]
        let count: Int
        let sizeMin: CGFloat
        let sizeMax: CGFloat
        let distMin: CGFloat
        let distMax: CGFloat
        let durMin: TimeInterval
        let durMax: TimeInterval
        let spin: Bool
        let stretch: CGFloat
    }

    /// 点赞红液滴：7 滴、2–4pt、9–19pt、480–620ms、沿飞行方向拉伸 1.3、不旋转。
    private static let likeStyle = Style(
        colors: [UIColor(red: 1, green: 59.0 / 255.0, blue: 48.0 / 255.0, alpha: 1),
                 UIColor(red: 1, green: 90.0 / 255.0, blue: 78.0 / 255.0, alpha: 1),
                 UIColor(red: 1, green: 138.0 / 255.0, blue: 122.0 / 255.0, alpha: 1),
                 UIColor(red: 1, green: 196.0 / 255.0, blue: 184.0 / 255.0, alpha: 1)],
        count: 7, sizeMin: 2, sizeMax: 4, distMin: 9, distMax: 19,
        durMin: 0.48, durMax: 0.62, spin: false, stretch: 1.3)

    /// 收藏星星：7 颗、2.5–4.5pt、10–21pt、500–660ms、带旋转。
    private static let starStyle = Style(
        colors: [UIColor(red: 1, green: 149.0 / 255.0, blue: 0, alpha: 1),
                 UIColor(red: 1, green: 169.0 / 255.0, blue: 77.0 / 255.0, alpha: 1),
                 UIColor(red: 1, green: 197.0 / 255.0, blue: 61.0 / 255.0, alpha: 1),
                 UIColor(red: 1, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1)],
        count: 7, sizeMin: 2.5, sizeMax: 4.5, distMin: 10, distMax: 21,
        durMin: 0.50, durMax: 0.66, spin: true, stretch: 1.0)

    /// 点赞变红时炸（只在变红时调；取消点赞调 clear(from:)）。
    static func burstLike(from button: UIButton) {
        burst(from: button, style: likeStyle, star: false)
    }

    /// 收藏变橙时炸（只在变橙时调；取消收藏不调）。
    static func burstStar(from button: UIButton) {
        burst(from: button, style: starStyle, star: true)
    }

    /// 清掉该按钮在飞的粒子（取消点赞、复用时调；无粒子时无害）。
    static func clear(from button: UIButton) {
        guard let host = button.superview else { return }
        for view in host.subviews {
            guard let overlay = view as? BearyBurstOverlayView, overlay.anchorButton === button else { continue }
            overlay.removeFromSuperview()
        }
    }

    private static func burst(from button: UIButton, style: Style, star: Bool) {
        guard BearyMotion.animated(true) else { return }
        guard let host = button.superview else { return }
        // 先清上一轮（快速连点不堆叠），再起新一轮。
        clear(from: button)
        let side: CGFloat = 120
        let overlay = BearyBurstOverlayView(frame: CGRect(
            x: button.center.x - side / 2, y: button.center.y - side / 2, width: side, height: side))
        overlay.anchorButton = button
        host.addSubview(overlay)
        let center = CGPoint(x: side / 2, y: side / 2)
        var remaining = style.count
        for index in 0..<style.count {
            let angle = (CGFloat.pi * 2 * CGFloat(index) / CGFloat(style.count)) + CGFloat.random(in: -0.35...0.35)
            let dist = CGFloat.random(in: style.distMin...style.distMax)
            let dx = cos(angle) * dist
            let dy = sin(angle) * dist
            let size = CGFloat.random(in: style.sizeMin...style.sizeMax)
            let color = style.colors[index % style.colors.count]
            let particle: UIView
            if star {
                particle = starView(size: size, color: color)
            } else {
                particle = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
                particle.backgroundColor = color
                particle.layer.cornerRadius = size / 2
            }
            particle.center = center
            particle.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            overlay.addSubview(particle)
            // 液滴沿飞行方向拉伸（先缩放到拉伸态、再转到飞行角、最后平移）；
            // 星星只转不拉伸。末段带 12pt 下坠（预览同款）。
            let midRotation: CGFloat = star ? CGFloat.random(in: 0.7...2.1) : angle
            let endRotation: CGFloat = star ? CGFloat.random(in: 2.1...3.84) : angle
            let midTransform = CGAffineTransform(translationX: dx * 0.7, y: dy * 0.7)
                .rotated(by: midRotation)
                .scaledBy(x: style.stretch, y: 1 / style.stretch)
            let endTransform = CGAffineTransform(translationX: dx, y: dy + 12)
                .rotated(by: endRotation)
                .scaledBy(x: 0.7, y: 0.7)
            let duration = TimeInterval.random(in: style.durMin...style.durMax)
            UIView.animateKeyframes(withDuration: duration, delay: 0, options: .calculationModeLinear, animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.55) {
                    particle.transform = midTransform
                }
                UIView.addKeyframe(withRelativeStartTime: 0.55, relativeDuration: 0.45) {
                    particle.transform = endTransform
                    particle.alpha = 0
                }
            }, completion: { _ in
                particle.removeFromSuperview()
                remaining -= 1
                if remaining == 0 {
                    overlay.removeFromSuperview()
                }
            })
        }
    }

    /// 四角星（预览同款 clip-path 顶点比例）。
    private static func starView(size: CGFloat, color: UIColor) -> UIView {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: size, height: size))
        view.backgroundColor = .clear
        let points: [(CGFloat, CGFloat)] = [
            (0.5, 0), (0.62, 0.38), (1, 0.5), (0.62, 0.62),
            (0.5, 1), (0.38, 0.62), (0, 0.5), (0.38, 0.38),
        ]
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            let target = CGPoint(x: point.0 * size, y: point.1 * size)
            if index == 0 {
                path.move(to: target)
            } else {
                path.addLine(to: target)
            }
        }
        path.close()
        let layer = CAShapeLayer()
        layer.frame = view.bounds
        layer.path = path.cgPath
        layer.fillColor = color.cgColor
        view.layer.addSublayer(layer)
        return view
    }
}
