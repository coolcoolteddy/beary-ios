import UIKit

// ===== 限时日记虚线气泡（2026-11-19 预览定版）=====
// 预览 Space xian-shi-ri-ji-yang-shi-yu-lan 的最终样式值（以源码为准）：
// 气泡圆角矩形 22、2pt 虚线边、内边距上下 20／左右 26；左上角 12×12 旋转 45°
// 尖尖（top -5、left 12，上／左两条虚线边、尖角微圆 3，尖角朝上对着左上方头像）；
// 四档：充裕（>6 小时）灰 #8f8f8c、临近（1–6 小时）暖黄 #e8b34b、
// 紧急（<1 小时）橙 #ff7a45（＋1.6s 呼吸微光）、已到期虚线 #55554f＋整体 0.55 淡出；
// 气泡底深 #1d1d1f／浅 #f4f4f2。
// 本视图是卡片与详情页共用的气泡容器：调用方把标题／正文 label 按顺序放进
// textStack，视图按自身 bounds 重画边框与尖尖，不依赖调用方的布局时机。
// 注意：容器保持默认可交互——正文里的内联 GIF 覆盖层挂在 label 自身下面
// （长按手势在覆盖层上），容器关交互会连带掐掉长按；容器本身无手势，
// 不拦卡片行选与滚动。
final class BearyLimitedBubbleView: UIView {

    /// 四档态与 BearyEphemeral.CountdownState 同型（调用方直接传倒计时档位）。
    typealias State = BearyEphemeral.CountdownState

    /// 内边距（预览值）：上下 20、左右 26。
    static let verticalPadding: CGFloat = 20
    static let horizontalPadding: CGFloat = 26
    /// 圆角（预览值）与描边宽（预览值 2pt）。
    static let cornerRadius: CGFloat = 22
    static let borderWidth: CGFloat = 2

    /// 气泡内文字栈：调用方把标题／正文 label 按顺序放进来；栈间距 6（标题→正文，
    /// 与卡片原口径一致；标题隐藏时栈自动忽略该间距）。
    let textStack: UIStackView = {
        let st = UIStackView()
        st.translatesAutoresizingMaskIntoConstraints = false
        st.axis = .vertical
        st.alignment = .fill
        st.distribution = .fill
        st.spacing = 6
        st.isLayoutMarginsRelativeArrangement = true
        st.layoutMargins = UIEdgeInsets(
            top: verticalPadding, left: horizontalPadding,
            bottom: verticalPadding, right: horizontalPadding
        )
        return st
    }()

    private let borderLayer = CAShapeLayer()
    private let tailFillLayer = CAShapeLayer()
    private let tailStrokeLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private var state: State = .calm

    /// 尖尖几何（预览值）：12×12 方块，左上角 top -5、left 12，旋转 45°。
    /// 旋转后菱形中心 (18, 1)，四顶点：上 (18, -7.49)、右 (26.49, 1)、
    /// 下 (18, 9.49)、左 (9.51, 1)；尖角即上顶点，朝上对着左上方头像。
    private enum Tail {
        static let size: CGFloat = 12
        static let left: CGFloat = 12
        static let top: CGFloat = -5
        static var center: CGPoint { CGPoint(x: left + size / 2, y: top + size / 2) }
        static var tip: CGPoint { CGPoint(x: center.x, y: center.y - size / sqrt(2)) }
        static var right: CGPoint { CGPoint(x: center.x + size / sqrt(2), y: center.y) }
        static var bottom: CGPoint { CGPoint(x: center.x, y: center.y + size / sqrt(2)) }
        static var leftVertex: CGPoint { CGPoint(x: center.x - size / sqrt(2), y: center.y) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        borderLayer.fillColor = BearyColors.limitedBubbleBg.cgColor
        borderLayer.lineWidth = Self.borderWidth
        borderLayer.lineDashPattern = [8, 5]
        borderLayer.strokeColor = BearyColors.limitedCalmDash.cgColor
        layer.addSublayer(borderLayer)
        tailFillLayer.fillColor = BearyColors.limitedBubbleBg.cgColor
        layer.addSublayer(tailFillLayer)
        tailStrokeLayer.fillColor = UIColor.clear.cgColor
        tailStrokeLayer.lineWidth = Self.borderWidth
        tailStrokeLayer.lineDashPattern = [4, 3]
        tailStrokeLayer.lineJoin = .round
        tailStrokeLayer.lineCap = .round
        tailStrokeLayer.strokeColor = BearyColors.limitedCalmDash.cgColor
        layer.addSublayer(tailStrokeLayer)
        glowLayer.fillColor = UIColor.clear.cgColor
        glowLayer.lineWidth = 5
        glowLayer.strokeColor = BearyColors.limitedUrgent.cgColor
        glowLayer.opacity = 0
        layer.addSublayer(glowLayer)
        addSubview(textStack)
        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: topAnchor),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 按四档状态刷描边色／虚线实线／淡出／微光；到期为实线边＋整体 0.55。
    func apply(state: State) {
        self.state = state
        let dashColor: UIColor
        switch state {
        case .calm: dashColor = BearyColors.limitedCalmDash
        case .near: dashColor = BearyColors.limitedNear
        case .urgent: dashColor = BearyColors.limitedUrgent
        case .expired: dashColor = BearyColors.limitedExpiredDash
        }
        borderLayer.strokeColor = dashColor.cgColor
        borderLayer.lineDashPattern = state == .expired ? nil : [8, 5]
        tailStrokeLayer.strokeColor = dashColor.cgColor
        tailStrokeLayer.lineDashPattern = state == .expired ? nil : [4, 3]
        alpha = state == .expired ? 0.55 : 1.0
        updateGlow()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        borderLayer.frame = bounds
        borderLayer.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2),
            cornerRadius: Self.cornerRadius
        ).cgPath
        tailFillLayer.frame = bounds
        tailFillLayer.path = diamondPath().cgPath
        tailStrokeLayer.frame = bounds
        tailStrokeLayer.path = tailUpperEdgesPath().cgPath
        glowLayer.frame = bounds
        glowLayer.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: -2.5, dy: -2.5),
            cornerRadius: Self.cornerRadius + 2.5
        ).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 气泡底是深浅自适应色：CGColor 快照须在主题切换时重刷（虚线色是固定值，不用刷）。
        borderLayer.fillColor = BearyColors.limitedBubbleBg.cgColor
        tailFillLayer.fillColor = BearyColors.limitedBubbleBg.cgColor
    }

    /// 尖尖菱形全路径（填充用气泡底色，盖住其下那段虚线边，与预览 ::before 同理）。
    private func diamondPath() -> UIBezierPath {
        let path = UIBezierPath()
        path.move(to: Tail.tip)
        path.addLine(to: Tail.right)
        path.addLine(to: Tail.bottom)
        path.addLine(to: Tail.leftVertex)
        path.close()
        return path
    }

    /// 尖尖上半两条虚线边（左顶点→尖角→右顶点；尖角处 3pt 微圆，预览值）。
    private func tailUpperEdgesPath() -> UIBezierPath {
        let path = UIBezierPath()
        // 尖角微圆：两边在距尖角 3pt 处收进圆角控制点（预览 border-top-left-radius:3）。
        let tipRound: CGFloat = 3
        let leftApproach = CGPoint(
            x: Tail.tip.x - tipRound * 0.7,
            y: Tail.tip.y + tipRound * 0.7
        )
        let rightApproach = CGPoint(
            x: Tail.tip.x + tipRound * 0.7,
            y: Tail.tip.y + tipRound * 0.7
        )
        path.move(to: Tail.leftVertex)
        path.addLine(to: leftApproach)
        path.addQuadCurve(to: rightApproach, controlPoint: Tail.tip)
        path.addLine(to: Tail.right)
        return path
    }

    /// 紧急档呼吸微光（预览 1.6s 呼吸环）：减动效下不播、不留光。
    private func updateGlow() {
        glowLayer.removeAnimation(forKey: "bearyLimitedBubbleGlow")
        guard state == .urgent, UIAccessibility.isReduceMotionEnabled == false else {
            glowLayer.opacity = 0
            return
        }
        glowLayer.opacity = 0.13
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.0
        pulse.toValue = 0.13
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowLayer.add(pulse, forKey: "bearyLimitedBubbleGlow")
    }
}

// MARK: - 限时 pill（作者行时间后；13 semibold，按态取色：存活限时深紫、到期私密深蓝）

/// 限时／私密 pill：存活“限时”虚线深紫边、到期“私密”实线深蓝边（与气泡虚实同理；
/// 规范 §九：限时深紫字＋深紫边、私密深蓝字＋深蓝边，G6 对比度修复）。本身就是 UILabel，作者行 firstBaseline
/// 对齐走文字基线，与名字／时间天然对齐（不要用 UIView 容器＋viewForFirstBaselineLayout
/// override——该方法在本工程 SDK 下不成立，编译报错；容器底边对齐又会让 pill
/// 文字比时间高约 8pt）。
final class BearyLimitedPillView: UILabel {

    /// pill 内边距（左右 10、上下 3）。
    private let insets = UIEdgeInsets(top: 3, left: 10, bottom: 3, right: 10)

    /// 当前态（存活限时／到期私密）：文字色与边色跟随态（存活深紫、到期深蓝），
    /// 深浅切换时重刷（CGColor 快照）。
    private var isExpired = false
    private var stateColor: UIColor { isExpired ? BearyColors.deepBlueText : BearyColors.deepPurpleText }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        textColor = BearyColors.deepPurpleText
        numberOfLines = 1
        layer.cornerRadius = 999
        layer.borderWidth = 1.5
        layer.borderColor = BearyColors.deepPurpleText.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 文字按内边距绘制／量尺寸（UILabel 内边距标准写法）。
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        var size = super.intrinsicContentSize
        size.width += insets.left + insets.right
        size.height += insets.top + insets.bottom
        return size
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }

    /// 存活“限时”虚线边／到期“私密”实线边；边色与文字色跟随态（存活深紫、
    /// 到期深蓝；CGColor 快照，主题切换时重刷）。
    func configure(text: String, expired: Bool) {
        self.text = text
        isExpired = expired
        textColor = stateColor
        layer.borderColor = stateColor.cgColor
        if expired {
            layer.borderWidth = 1.5
            // 实线边：用 borderWidth 走实线；虚线用 dashedLayer 才画得出，
            // 故虚线态另挂 dashedLayer（见下）。
            dashedLayer.isHidden = true
        } else {
            layer.borderWidth = 0
            dashedLayer.strokeColor = stateColor.cgColor
            dashedLayer.isHidden = false
        }
        setNeedsLayout()
    }

    private lazy var dashedLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [4, 3]
        self.layer.addSublayer(layer)
        return layer
    }()

    override func layoutSubviews() {
        super.layoutSubviews()
        dashedLayer.frame = bounds
        dashedLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        layer.borderColor = stateColor.cgColor
        dashedLayer.strokeColor = stateColor.cgColor
    }
}
