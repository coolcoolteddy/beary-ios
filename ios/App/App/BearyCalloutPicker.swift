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
    // isHidden，从 viewDidLoad 起就吃掉编辑器全部点按，而 tap 手势的 hideCallout
    // 因 activeCallout 为 nil 直接早退，表面上什么都不发生；光标仍闪是因为第一
    // 响应者与键盘不受触摸拦截影响）。穿透区语义不变：工具栏点返回 nil 落到下层钮。
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

/// 编辑器尖角弹出框（2026-10-29 编辑器改版：心情/天气选择器）。
/// iPhone 上 UIPopoverPresentationController 会落成 sheet，不是这个形态，
/// 故做自定义 callout：框体圆角 16、底边小尖角对齐触发图标中心，
/// 框内横向可滑一排选项（右边缘半露下一个 + 渐隐，示意可滑）。
/// 出现/消失只走 transform/opacity；减动效由调用方静态直出（本视图不自播动画）。
/// 横滑条专用滚动视图：框内 delaysContentTouches=false（点按立即响应）时，
/// 从选项按钮上起滑会滑不动——系统默认 touchesShouldCancel 对 UIControl 返回 false，
/// 按钮会一直占住触摸、滚动视图抢不到 pan；空白处起滑（非 UIControl）则正常。
/// 这里一律返回 true：拖动时按钮收 touchesCancelled（bearyAddPressFeedback 的
/// touchCancel 回弹复位），点按（无拖动）不触发取消、照常走 touchUpInside。
final class BearyCalloutScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

final class BearyCalloutPickerView: UIView, UIScrollViewDelegate {
    struct Option {
        let key: String
        let accessibilityLabel: String
    }

    /// 尖角顶点在本视图坐标系的 x（调用方按触发图标中心设；布局时钳制在框内）。
    var arrowCenterX: CGFloat = 0 {
        didSet {
            if arrowCenterX != oldValue {
                setNeedsLayout()
            }
        }
    }

    var onSelect: ((String) -> Void)?
    /// 取图闭包：(key, dark) -> 图。心情走 emote 静态 PNG（深色 _dark），
    /// 天气走 icon_wx_* 模板图（调用方 tint 墨色，深浅自适应）。
    var imageProvider: ((String, Bool) -> UIImage?)?

    private static let arrowHeight: CGFloat = 10
    private static let arrowHalfWidth: CGFloat = 8
    private static let cornerRadius: CGFloat = 12
    private static let verticalPadding: CGFloat = 10
    private static let horizontalPadding: CGFloat = 12
    private static let optionSize: CGFloat = 48
    private static let optionSpacing: CGFloat = 8
    private static let fadeWidth: CGFloat = 28

    /// 浅色 faint 底、深色 #26262c 底（不用 BearyColors.faint 直代：
    /// 其深色是 white.08，不是本框要的 #26262c）。
    private static var calloutBackgroundColor: UIColor {
        UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 38.0 / 255.0, green: 38.0 / 255.0, blue: 44.0 / 255.0, alpha: 1)
            }
            return UIColor(white: 0.96, alpha: 1)
        }
    }

    private let backgroundLayer = CAShapeLayer()
    private let scrollView = BearyCalloutScrollView()
    private let stackView = UIStackView()
    private let fadeView = UIView()
    private let fadeLayer = CAGradientLayer()
    private var optionButtons: [(key: String, button: UIButton)] = []

    private var boxHeight: CGFloat {
        Self.verticalPadding * 2 + Self.optionSize
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        layer.addSublayer(backgroundLayer)
        backgroundLayer.shadowColor = UIColor.black.cgColor
        backgroundLayer.shadowOpacity = 0.15
        backgroundLayer.shadowRadius = 8
        backgroundLayer.shadowOffset = CGSize(width: 0, height: 2)
        scrollView.showsHorizontalScrollIndicator = false
        // 天气条同款教训：横滑条内选项点按易被 scroll 误判为滑动而取消；
        // 关掉触摸延迟，点按立即响应。
        scrollView.delaysContentTouches = false
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = Self.optionSpacing
        stackView.alignment = .center
        addSubview(scrollView)
        scrollView.addSubview(stackView)
        fadeView.isUserInteractionEnabled = false
        fadeView.layer.addSublayer(fadeLayer)
        addSubview(fadeView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: Self.verticalPadding),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -Self.verticalPadding),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: Self.horizontalPadding),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -Self.horizontalPadding),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(options: [Option], onSelect: ((String) -> Void)?, imageProvider: ((String, Bool) -> UIImage?)?) {
        self.onSelect = onSelect
        self.imageProvider = imageProvider
        // 32 清单第 31 项：先 removeArrangedSubview 再 removeFromSuperview（纯防御性；
        // 现状两实例 configure 各只调一次，旧按钮本就不会残留，收益为零，仍按拍板做）。
        for (_, button) in optionButtons {
            stackView.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        optionButtons.removeAll()
        for option in options {
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.accessibilityLabel = option.accessibilityLabel
            button.tintColor = BearyColors.ink
            button.imageView?.contentMode = .scaleAspectFit
            button.addTarget(self, action: #selector(didTapOption(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: Self.optionSize),
                button.heightAnchor.constraint(equalToConstant: Self.optionSize),
            ])
            stackView.addArrangedSubview(button)
            optionButtons.append((key: option.key, button: button))
        }
        refreshImages()
        setNeedsLayout()
    }

    /// 深浅切换时重取图（心情 _dark 资产）+ 重算底色与渐隐色。
    func refreshImages() {
        let dark = traitCollection.userInterfaceStyle == .dark
        for (key, button) in optionButtons {
            button.setImage(imageProvider?(key, dark), for: .normal)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshImages()
            updateBackgroundColors()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = boxHeight
        backgroundLayer.frame = bounds
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: height)
        fadeView.frame = CGRect(x: width - Self.fadeWidth, y: 0, width: Self.fadeWidth, height: height)
        fadeLayer.frame = fadeView.bounds
        // 尖角钳制：顶点离左右边各留半宽 + 4pt，三角不伸出框外。
        let clampedX = min(max(arrowCenterX, Self.arrowHalfWidth + 4), max(width - Self.arrowHalfWidth - 4, Self.arrowHalfWidth + 4))
        let box = CGRect(x: 0, y: 0, width: width, height: height)
        let path = UIBezierPath(roundedRect: box, cornerRadius: Self.cornerRadius)
        path.move(to: CGPoint(x: clampedX - Self.arrowHalfWidth, y: height))
        path.addLine(to: CGPoint(x: clampedX, y: height + Self.arrowHeight))
        path.addLine(to: CGPoint(x: clampedX + Self.arrowHalfWidth, y: height))
        path.close()
        backgroundLayer.path = path.cgPath
        updateBackgroundColors()
        // 先落一次滚动区子树布局，contentSize 落定后再判渐隐（首帧 contentSize 否则仍为 0）。
        scrollView.layoutIfNeeded()
        updateFadeVisibility()
    }

    private func updateBackgroundColors() {
        let bg = Self.calloutBackgroundColor.resolvedColor(with: traitCollection)
        backgroundLayer.fillColor = bg.cgColor
        fadeLayer.colors = [bg.withAlphaComponent(0).cgColor, bg.cgColor]
        fadeLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fadeLayer.endPoint = CGPoint(x: 1, y: 0.5)
    }

    private func updateFadeVisibility() {
        // 内容放得下、或已滑到最右时不渐隐；否则右边缘渐隐示意可滑。
        let contentWidth = scrollView.contentSize.width
        let visibleWidth = scrollView.bounds.width
        if contentWidth <= visibleWidth + 1 {
            fadeView.isHidden = true
            return
        }
        fadeView.isHidden = scrollView.contentOffset.x >= contentWidth - visibleWidth - 1
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateFadeVisibility()
    }

    @objc private func didTapOption(_ sender: UIButton) {
        for (key, button) in optionButtons where button == sender {
            onSelect?(key)
            return
        }
    }
}
