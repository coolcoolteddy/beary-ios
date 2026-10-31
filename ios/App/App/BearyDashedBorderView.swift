import UIKit

// ===== 限时虚线边框视图（116 批：我的页底边缺失 + 时间线引用出框）=====
// 此前虚线框是挂在宿主层上的 CAShapeLayer，path 只在宿主 cell 的
// layoutSubviews 里按当时 contentView/cardView.bounds 手工重算：行高或内容高
// 尚未落定那一刻画出的矩形，落定后若 cell 的 layoutSubviews 不再跑一次，
// 框就停留在旧矩形上——我的页表现为底边被下一行盖住，时间线表现为框高
// 不含引用卡。本视图把 path 交给自身 layoutSubviews：视图本身由约束钉在
// 宿主容器上（时间线：cardView 内缩 8/6；卡片：contentView 内缩 8/6，首卡
// 顶 22），自身 bounds 一变就重画，不再依赖宿主 cell 的布局时机。
// 口径一字不动：1.5pt、虚线 [4, 3]、圆角 16、line 色；不拦截点按。
final class BearyDashedBorderView: UIView {

    private let borderLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.lineWidth = 1.5
        borderLayer.lineDashPattern = [4, 3]
        borderLayer.strokeColor = BearyColors.line.cgColor
        layer.addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        borderLayer.frame = bounds
        borderLayer.path = UIBezierPath(roundedRect: bounds, cornerRadius: 16).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 描边色是 CGColor 快照，深浅切换须重刷（与旧层口径一致）。
        borderLayer.strokeColor = BearyColors.line.cgColor
    }
}
