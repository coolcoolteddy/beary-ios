import UIKit

/// 框外点按承接层（编辑器改版 2026-10-29：心情/天气尖角弹出框）。
/// 盖住编辑器全域、垫在弹出框之下；点按即收起（不改选中值）。
/// 工具栏区域设为穿透（hitTest 返回 nil），工具栏按钮仍可点按：
/// 再点同图标收起、点另一图标切换、点图片/@/引用走各自处理（调用方收起框）。
final class BearyCalloutDismissView: UIView {
    /// 穿透区（本视图坐标系），一般为工具栏容器帧。
    var passthroughRects: [CGRect] = []
    var onTapOutside: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // hitTest 自定义必须先复刻系统默认门：isHidden / alpha /
    // isUserInteractionEnabled / bounds 任一不满足即返回 nil，否则隐藏的收起层
    // 也会拦截全屏触摸（102 真机事故：收起层建时即隐藏，但自定义 hitTest 未查
    // isHidden，从 viewDidLoad 起就吃掉编辑器全部点按，而点按收起的回调因当时
    // 未开框直接早退，表面上什么都不发生；光标仍闪是因为第一响应者与键盘不受
    // 触摸拦截影响）。穿透区语义不变：工具栏点返回 nil 落到下层钮。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled, self.point(inside: point, with: event) else { return nil }
        for rect in passthroughRects where rect.contains(point) {
            return nil
        }
        return self
    }

    @objc private func didTap() {
        onTapOutside?()
    }
}

/// 时间线筛子尖角气泡（11b：筛子从系统 actionSheet 改回尖角气泡）。
/// 壳口径沿用旧编辑器尖角框同款：框体圆角 16、尖角高 10/半宽 8、浅色 #F5F5F5 /
/// 深色 #18181C（surface3）、hairline 阴影；框外收起直接复用 BearyCalloutDismissView
/// （不另写收起层）。尖角改放框顶（筛子钮在表头、气泡朝下展开，框在钮下方、尖角向上
/// 指钮中心——与旧编辑器“框在上、尖角朝下指钮”镜像）。
/// 出现/消失只走 transform/opacity（0.18s、6pt；减动效静态直出，本视图不自播动画）。
final class BearyBubbleMenuView: UIView {
    struct Row {
        let key: String
        let title: String
    }

    var onSelect: ((String) -> Void)?

    /// 尖角顶点在本视图坐标系的 x（调用方按触发钮中心设；布局时钳制在框内）。
    var arrowCenterX: CGFloat = 0 {
        didSet {
            if arrowCenterX != oldValue {
                setNeedsLayout()
            }
        }
    }

    private static let arrowHeight: CGFloat = 10
    private static let arrowHalfWidth: CGFloat = 8
    private static let cornerRadius: CGFloat = BearyCorners.single
    private static let verticalPadding: CGFloat = 8
    private static let horizontalPadding: CGFloat = 8
    private static let rowHeight: CGFloat = 44
    private static let separatorHeight: CGFloat = 0.5

    /// 气泡底走 surface3（2026-11-11 视觉审计第 9 项：旧硬编码值深 #26262c／浅 white 0.96
    /// 已随 surface 单值废止，改走 surface3 token）。
    private static var bubbleBackgroundColor: UIColor {
        BearyColors.surface3
    }

    /// 调用方按此算框高（尖角 + 上下内边距 + 各行 + 行间细线），不另算。
    static func menuHeight(rowCount: Int) -> CGFloat {
        Self.arrowHeight + Self.verticalPadding * 2 + CGFloat(rowCount) * Self.rowHeight
            + CGFloat(max(0, rowCount - 1)) * Self.separatorHeight
    }

    private let backgroundLayer = CAShapeLayer()
    private let stackView = UIStackView()
    private var rowViews: [(key: String, row: RowView)] = []
    private var selectedKey: String?
    private var stackConstraintsInstalled = false

    /// 气泡行（普通 UIView，不用 UIButton）：UIButton 的 isSelected/各态
    /// 标题色/背景渲染机器是选中行黑块的嫌疑源——#810 把背景与各态色
    /// 显式钉死仍复现；改成视图行后，选中态只剩半粗体＋对勾，无任何
    /// 系统态渲染可画出深色底。
    private final class RowView: UIView {
        let key: String
        private let iconView = UIImageView()
        private let titleLabel = UILabel()
        var onTap: ((String) -> Void)?

        init(key: String, title: String) {
            self.key = key
            super.init(frame: .zero)
            backgroundColor = .clear
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.contentMode = .scaleAspectFit
            iconView.tintColor = BearyColors.ink
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
            titleLabel.adjustsFontForContentSizeCategory = true
            titleLabel.textColor = BearyColors.ink
            titleLabel.backgroundColor = .clear
            titleLabel.text = title
            let rowStack = UIStackView(arrangedSubviews: [iconView, titleLabel])
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.axis = .horizontal
            rowStack.spacing = 8
            rowStack.alignment = .center
            addSubview(rowStack)
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 24),
                iconView.heightAnchor.constraint(equalToConstant: 24),
                rowStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                rowStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
                rowStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            isAccessibilityElement = true
            accessibilityLabel = title
            let tap = UITapGestureRecognizer(target: self, action: #selector(didTap))
            addGestureRecognizer(tap)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setSelected(_ selected: Bool) {
            titleLabel.font = BearyDynamicType.scaledFont(
                for: selected ? UIFont.boldSystemFont(ofSize: 15) : UIFont.systemFont(ofSize: 15))
            iconView.image = selected
                ? BearyIconImages.image(named: "icon_check", pointSize: 24)
                : BearyBubbleMenuView.clearPlaceholderImage(pointSize: 24)
            accessibilityTraits = selected ? [.button, .selected] : [.button]
        }

        @objc private func didTap() {
            onTap?(key)
        }

        /// 自绘菜单行由手势处理触摸；VoiceOver 激活使用同一选择回调。
        override func accessibilityActivate() -> Bool {
            onTap?(key)
            return true
        }

        // 按压反馈：微缩，松手/取消回弹（UIButton 版按压反馈是
        // UIControl 专属，视图行自带同款手感）。
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            UIView.animate(withDuration: BearyMotion.animated(true) ? BearyMotion.micro : 0,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: { self.transform = CGAffineTransform(scaleX: 0.98, y: 0.98) })
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            UIView.animate(withDuration: BearyMotion.animated(true) ? BearyMotion.micro : 0,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: { self.transform = .identity })
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            UIView.animate(withDuration: BearyMotion.animated(true) ? BearyMotion.micro : 0,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: { self.transform = .identity })
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        layer.addSublayer(backgroundLayer)
        BearyShadow.applyHairline(to: backgroundLayer)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 0
        addSubview(stackView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(rows: [Row], selectedKey: String?, onSelect: ((String) -> Void)?) {
        self.onSelect = onSelect
        self.selectedKey = selectedKey
        for (_, row) in rowViews {
            stackView.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rowViews.removeAll()
        // 旧分隔线一并清掉（分隔线不是行成员，单独扫一遍）。
        for arranged in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let separator = UIView()
                // 分隔线走 gray：气泡底是 surface3，line（浅 #DBDBDB）与 surface3
                // （浅 #F5F5F5）对比约 1.27:1、浅色下几不可见（#1286 档距拉大后）。
                separator.backgroundColor = BearyColors.gray
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.heightAnchor.constraint(equalToConstant: Self.separatorHeight).isActive = true
                stackView.addArrangedSubview(separator)
            }
            let rowView = RowView(key: row.key, title: row.title)
            rowView.translatesAutoresizingMaskIntoConstraints = false
            rowView.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            rowView.onTap = { [weak self] key in self?.onSelect?(key) }
            stackView.addArrangedSubview(rowView)
            rowViews.append((key: row.key, row: rowView))
        }
        if !stackConstraintsInstalled {
            stackConstraintsInstalled = true
            NSLayoutConstraint.activate([
                stackView.topAnchor.constraint(equalTo: topAnchor, constant: Self.arrowHeight + Self.verticalPadding),
                stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
                stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
                stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
            ])
        }
        refreshSelectedStates()
        setNeedsLayout()
    }

    /// 打开时刷新选中态（不重建行）：选中行半粗体 + 左侧官方 icon_check
    /// + .selected 无障碍 trait；未选中行垫同尺寸透明图，标题左对齐不漂移。
    func setSelectedKey(_ key: String?) {
        selectedKey = key
        refreshSelectedStates()
    }

    private func refreshSelectedStates() {
        for (key, row) in rowViews {
            row.setSelected(selectedKey != nil && key == selectedKey)
        }
    }

    fileprivate static func clearPlaceholderImage(pointSize: CGFloat) -> UIImage {
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateBackgroundColors()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        backgroundLayer.frame = bounds
        // 尖角钳制：顶点离左右边各留半宽 + 4pt，三角不伸出框外（CalloutPicker 同款）。
        let clampedX = min(max(arrowCenterX, Self.arrowHalfWidth + 4), max(width - Self.arrowHalfWidth - 4, Self.arrowHalfWidth + 4))
        let box = CGRect(x: 0, y: Self.arrowHeight, width: width, height: max(0, height - Self.arrowHeight))
        let path = UIBezierPath(roundedRect: box, cornerRadius: Self.cornerRadius)
        path.move(to: CGPoint(x: clampedX - Self.arrowHalfWidth, y: Self.arrowHeight))
        path.addLine(to: CGPoint(x: clampedX, y: 0))
        path.addLine(to: CGPoint(x: clampedX + Self.arrowHalfWidth, y: Self.arrowHeight))
        path.close()
        backgroundLayer.path = path.cgPath
        updateBackgroundColors()
    }

    private func updateBackgroundColors() {
        backgroundLayer.fillColor = Self.bubbleBackgroundColor.resolvedColor(with: traitCollection).cgColor
    }
}
