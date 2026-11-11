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
    /// 审计第 31 项：VoiceOver 逃离（两指划）回调。框体是普通叠加层、非 VC，
    /// 逃离手势无 VC 可接，须由框体自身响应（信件模态遮罩层同款做法）：
    /// 调用方接成与框外点按同一关闭路径并还焦点。未接时返回 false，不谎称已处理。
    var onAccessibilityEscape: (() -> Void)?
    /// 审计第 31 项：打开时 VoiceOver 首落点——已选中的可见选项优先（与框内
    /// 选中态同一口径），无选中或选中项取图失败被隐藏时落首个可见选项；
    /// 全部选项都被隐藏时返回 nil，调用方此时不发焦点通知、不抢焦点。
    /// 只读现有选项按钮与 isHidden，不改选项内容、布局与选中逻辑。
    var initialAccessibilityElement: UIView? {
        if let selectedKey = selectedKey {
            for (key, button) in optionButtons where !button.isHidden && key == selectedKey {
                return button
            }
        }
        return optionButtons.map(\.button).first(where: { !$0.isHidden })
    }

    override func accessibilityPerformEscape() -> Bool {
        guard let onAccessibilityEscape = onAccessibilityEscape else { return false }
        onAccessibilityEscape()
        return true
    }

    /// 取图闭包：(key, dark) -> 图。心情走 emote 静态 PNG（深色 _dark），
    /// 天气走 icon_wx_* 模板图（调用方 tint 墨色，深浅自适应）。
    var imageProvider: ((String, Bool) -> UIImage?)?
    /// 动画图标 key 注入：返回 Lottie key 则该选项贴 BearyEmoteView 覆盖层
    /// （底层静态图作 fallback）；返回 nil 的选项保持纯静态（心情框）。
    /// 呼出框隐藏时播放器不自动停，须调用方 show/hide 时播／停。
    var emoteKeyProvider: ((String) -> String?)?
    private var emoteOverlays: [String: BearyEmoteView] = [:]
    /// 审计 E2 第 11 项：当前选中项的 key（天气单选用；心情是插入操作，
    /// 不套用本样式，调用方不传即无选中态）。“无”选项（key "none"）与
    /// 其他天气项沿用同一表现：轻量墨色描边 + selected 无障碍状态。
    /// Composer 侧已接：buildCallouts 的 weatherCallout.configure 传
    /// selectedWeather；打开天气框时 showCallout 再调 setSelectedKey
    /// (selectedWeather) 同步（configure 只在搭建时调一次，编辑/草稿的
    /// 天气晚于搭建才落定，故打开时同步是生效的一步）。无天气时传 nil，
    /// 框内无行高亮。
    private(set) var selectedKey: String?

    private static let arrowHeight: CGFloat = 10
    private static let arrowHalfWidth: CGFloat = 8
    private static let cornerRadius: CGFloat = BearyCorners.single
    private static let verticalPadding: CGFloat = 10
    private static let horizontalPadding: CGFloat = 12
    private static let optionSize: CGFloat = 48
    private static let optionSpacing: CGFloat = 8
    private static let fadeWidth: CGFloat = 28

    /// 浮层底走 surface3（2026-11-07 微明度定版：旧硬编码值深 #26262c／浅 #F5F5F5
    /// 已随 surface 单值废止，改走 surface3 token）。
    private static var calloutBackgroundColor: UIColor {
        BearyColors.surface3
    }

    private let backgroundLayer = CAShapeLayer()
    private let scrollView = BearyCalloutScrollView()
    private let stackView = UIStackView()
    private let fadeView = UIView()
    private let fadeLayer = CAGradientLayer()
    private var optionButtons: [(key: String, button: UIButton)] = []

    /// [24] 审计后续小项 2：面板内附属行（仅天气框用，装气温步进器）。
    /// 框体不替附属行做业务：只给它一行固定高的位置（自然宽、左对齐），
    /// 附属行自身的按钮/动作仍归调用方；心情框不设附属行，几何一字不动。
    private var accessoryView: UIView?
    private static let accessoryGap: CGFloat = 8
    private static let accessoryRowHeight: CGFloat = 36

    /// 审计四轮 09：脚注行（仅天气框用，写清精确位置的去向）。附属行是
    /// 气温步进器，脚注是另一行说明文字：有附属行时贴在附属行下方，无附
    /// 属行（未选天气、步进器藏起）时直接贴框顶；两种落点都不占图标条
    /// 的位置，框高增量由 accessoryExtraHeight 统一算，调用方不用另算。
    /// 跟随动态字号：12pt 语义入口（captionFont），大字号时允许多行、
    /// 框高跟着长（见 footerNoteHeight／refreshFooterHeight）；常规字号
    /// 下与旧 34pt 两行一致。
    private var footerNoteLabel: UILabel?
    private var footerTopConstraint: NSLayoutConstraint?
    private var footerHeightConstraint: NSLayoutConstraint?
    private static let footerGap: CGFloat = 8
    /// 脚注高变化回调：脚注高随字号/宽度变化时，调用方刷新框高约束
    ///（见 Composer updateWeatherCalloutHeight）。
    var onFooterHeightChange: (() -> Void)?

    /// 脚注实高（跟随动态字号）：按当前缩放字号与实际文案行数算；
    /// 常规字号下与旧 34pt 一致（两行 12pt 文案约 29pt，留余量到 34）。
    private var footerNoteHeight: CGFloat {
        guard let text = footerNoteLabel?.text, !text.isEmpty else { return 0 }
        let font = BearyDynamicType.captionFont()
        let width = bounds.width - Self.horizontalPadding * 2
        if width > 0 {
            let size = (text as NSString).boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font],
                context: nil).size
            return max(34, ceil(size.height))
        }
        // 尚未布局（宽未知）：按缩放字号估两行；打开前调用方会重算框高。
        return max(34, ceil(font.lineHeight * 2))
    }

    /// 脚注高随布局/字号同步：宽一定后按实际换行重算，变了才通知调用方
    /// 刷新框高约束（约束值不变时不回调，不触发多余布局）。
    private func refreshFooterHeight() {
        guard let constraint = footerHeightConstraint else { return }
        let height = footerNoteHeight
        guard constraint.constant != height else { return }
        constraint.constant = height
        onFooterHeightChange?()
    }

    /// 附属行显时框体比基准高出的部分（调用方据此定框高约束）。
    /// 附属行在图标条上方、图标条贴框底（箭头上方）：显隐只往上长，
    /// 图标条屏上位置不动（框底钉在工具栏上方，框高变化全由顶部吸收）。
    /// 增量 = 顶部内边距 + 附属行高 + 行间距；脚注另加一行（有附属行时
    /// 贴附属行下方，无附属行时贴框顶，两种情形各补一份顶部内边距）。
    var accessoryExtraHeight: CGFloat {
        var extra: CGFloat = 0
        if let accessory = accessoryView, !accessory.isHidden {
            extra += Self.verticalPadding + Self.accessoryGap + Self.accessoryRowHeight
        }
        if footerNoteLabel != nil {
            let accessoryHidden = accessoryView?.isHidden ?? true
            if accessoryHidden {
                extra += Self.verticalPadding
            }
            extra += footerNoteHeight + Self.footerGap
        }
        return extra
    }

    /// 脚注行：nil 即撤掉。落点随附属行显隐走（见 updateFooterLayout），
    /// 调用方只在搭建时调一次；附属行显隐变化时本框自行跟调，不用调用方管。
    func setFooterNote(_ text: String?) {
        footerNoteLabel?.removeFromSuperview()
        footerNoteLabel = nil
        footerTopConstraint = nil
        footerHeightConstraint = nil
        guard let text = text else { return }
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.captionFont()
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.numberOfLines = 0
        label.text = text
        addSubview(label)
        footerNoteLabel = label
        let top = label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding)
        footerTopConstraint = top
        let height = label.heightAnchor.constraint(equalToConstant: footerNoteHeight)
        footerHeightConstraint = height
        NSLayoutConstraint.activate([
            top,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
            height,
        ])
        updateFooterLayout()
        setNeedsLayout()
    }

    /// 脚注落点：有附属行时贴附属行下方，无附属行时贴框顶（附属行藏起
    /// 时不留 36pt 空洞）。附属行显隐变化与脚注设置时都调一次。
    private func updateFooterLayout() {
        guard let top = footerTopConstraint else { return }
        if let accessory = accessoryView, !accessory.isHidden {
            top.constant = Self.verticalPadding + Self.accessoryRowHeight + Self.accessoryGap
        } else {
            top.constant = Self.verticalPadding
        }
    }

    /// 附属行只在框内出现，不进调用方的 chip 行等外部布局；调用方须在
    /// 附属行显隐变化时同步刷新框高约束（见 Composer updateWeatherCalloutHeight）。
    func setAccessoryView(_ view: UIView?) {
        accessoryView?.removeFromSuperview()
        accessoryView = view
        guard let view = view else { return }
        // 附属行走常规 Auto Layout（顶／左／高约束＋自然宽，不再由 layoutSubviews
        // 手动落 frame）：手动 frame 下 stack view 子树布局时序不可靠，附属行
        // 曾出现“框高已长、行内按钮全无”的空白；改约束后按钮帧由布局引擎保证。
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
            view.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalPadding),
            view.heightAnchor.constraint(equalToConstant: Self.accessoryRowHeight),
        ])
        setNeedsLayout()
    }

    func setAccessoryVisible(_ visible: Bool) {
        guard accessoryView?.isHidden == visible else { return }
        accessoryView?.isHidden = !visible
        accessoryView?.setNeedsLayout()
        // 审计四轮 09：附属行显隐翻转时脚注落点跟着走（贴附属行下方 ↔ 贴框顶）。
        updateFooterLayout()
        setNeedsLayout()
    }

    private var boxHeight: CGFloat {
        Self.verticalPadding * 2 + Self.optionSize
    }

    private var fullBoxHeight: CGFloat {
        boxHeight + accessoryExtraHeight
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        layer.addSublayer(backgroundLayer)
        BearyShadow.applyHairline(to: backgroundLayer)
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

    func configure(options: [Option], onSelect: ((String) -> Void)?, imageProvider: ((String, Bool) -> UIImage?)?, emoteKeyProvider: ((String) -> String?)? = nil, selectedKey: String? = nil) {
        self.onSelect = onSelect
        self.imageProvider = imageProvider
        self.emoteKeyProvider = emoteKeyProvider
        self.selectedKey = selectedKey
        // 旧选项按钮重建时旧覆盖层一并摘掉（不留已离树的播放器）。
        for (_, overlay) in emoteOverlays {
            overlay.stop()
            overlay.removeFromSuperview()
        }
        emoteOverlays.removeAll()
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
        refreshSelectedStates()
        setNeedsLayout()
    }

    /// 打开框时刷新选中态（不重建选项）：调用方在选中值变化后调一次即可。
    func setSelectedKey(_ key: String?) {
        selectedKey = key
        refreshSelectedStates()
    }

    /// 选中态渲染：仅选中项 1pt 墨色描边（圆角 12，与框体同口径；
    /// 边框色走动态入口，深浅切换自动跟走），其余项无边框；
    /// 选中项同时置 isSelected 与 .selected 无障碍 trait。
    private func refreshSelectedStates() {
        for (key, button) in optionButtons {
            let selected = (selectedKey != nil && key == selectedKey)
            button.isSelected = selected
            button.accessibilityTraits = selected ? [.button, .selected] : [.button]
            if selected {
                button.layer.cornerRadius = 12
                button.layer.borderWidth = 1
                button.layer.bearyDynamicBorderColor = BearyColors.ink
            } else {
                button.layer.borderWidth = 0
                button.layer.bearyDynamicBorderColor = nil
            }
        }
    }

    /// 深浅切换时重取图（心情 _dark 资产）+ 重算底色与渐隐色。
    /// 审计登录杂项：取图为 nil 的选项直接隐藏（此前仍是 48×48 空白可点格）；
    /// 不自绘、不拿 SF Symbol 顶替；资产补齐后 refreshImages 会自动恢复显示。
    /// 注：本选择器为纯图片选项、无文字 label，故“字号改 scaledFont”一项不适用。
    func refreshImages() {
        let dark = traitCollection.userInterfaceStyle == .dark
        for (key, button) in optionButtons {
            let image = imageProvider?(key, dark)
            button.setImage(image, for: .normal)
            button.isHidden = (image == nil)
            refreshEmoteOverlay(for: key, button: button, image: image)
        }
    }

    /// 天气选项动画图标（落点行同款）：同 key 只重播、不重建；主题切换
    /// 走播放器内部处理；框隐藏／未进窗口时停播，打开时由调用方统一播。
    private func refreshEmoteOverlay(for key: String, button: UIButton, image: UIImage?) {
        guard let lottieKey = emoteKeyProvider?(key), let image, let imageView = button.imageView else {
            if let overlay = emoteOverlays.removeValue(forKey: key) {
                overlay.stop()
                overlay.removeFromSuperview()
            }
            return
        }
        if let existing = emoteOverlays[key], existing.superview === imageView, existing.emoteKey == lottieKey {
            if isHidden || window == nil { existing.stop() } else { existing.play() }
            return
        }
        if let old = emoteOverlays.removeValue(forKey: key) {
            old.stop()
            old.removeFromSuperview()
        }
        let overlay = BearyEmoteView(key: lottieKey, animated: true, fallbackImage: image)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        imageView.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: imageView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
        ])
        emoteOverlays[key] = overlay
        if isHidden || window == nil { overlay.stop() }
    }

    /// 呼出框显示／隐藏时由调用方播／停全部动画图标。
    func setEmoteOverlaysPlaying(_ playing: Bool) {
        for overlay in emoteOverlays.values {
            if playing { overlay.play() } else { overlay.stop() }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            refreshImages()
            updateBackgroundColors()
        }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            refreshFooterHeight()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshFooterHeight()
        let width = bounds.width
        let height = fullBoxHeight
        backgroundLayer.frame = bounds
        // 图标条贴框底（箭头上方），附属行在图标条上方：附属行显隐只往上长，
        // 图标条屏上位置不动（框底钉死、框高变化全由顶部吸收；点中图标不跑开）。
        // 附属行后加、层级在滚动区之上，两者在纵向不重叠，点按互不干扰。
        scrollView.frame = CGRect(x: 0, y: accessoryExtraHeight, width: width, height: boxHeight)
        fadeView.frame = CGRect(x: width - Self.fadeWidth, y: accessoryExtraHeight, width: Self.fadeWidth, height: boxHeight)
        // 附属行位置由 setAccessoryView 的约束定，不再此处手动落 frame。
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

/// 时间线筛子尖角气泡（11b：筛子从系统 actionSheet 改回尖角气泡）。
/// 壳口径 1:1 复用 BearyCalloutPickerView（编辑器心情/天气尖角框）：
/// 框体圆角 16、尖角高 10/半宽 8、浅色 #DFDFDF / 深色 #313138（surface3）、hairline 阴影；
/// 框外收起直接复用 BearyCalloutDismissView（不另写收起层）。
/// CalloutPicker 本体是横向 48pt 图标排、渲不出文字，故只复用其壳常量与
/// 路径画法，不硬套其本体。尖角改放框顶（筛子钮在表头、气泡朝下展开，
/// 框在钮下方、尖角向上指钮中心——与编辑器“框在上、尖角朝下指钮”镜像）。
/// 出现/消失只走 transform/opacity（0.20s、6pt，编辑器 showCallout 同款；
/// 减动效静态直出，本视图不自播动画）。
final class BearyBubbleMenuView: UIView {
    struct Row {
        let key: String
        let title: String
    }

    var onSelect: ((String) -> Void)?

    /// 尖角顶点在本视图坐标系的 x（调用方按触发钮中心设；布局时钳制在框内，
    /// 与 BearyCalloutPickerView.arrowCenterX 同口径）。
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

        // 按压反馈：轻震＋微缩，松手/取消回弹（UIButton 版按压反馈是
        // UIControl 专属，视图行自带同款手感）。
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            BearyHaptics.press()
            UIView.animate(withDuration: BearyMotion.animated(true) ? 0.13 : 0,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: { self.transform = CGAffineTransform(scaleX: 0.98, y: 0.98) })
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            UIView.animate(withDuration: BearyMotion.animated(true) ? 0.13 : 0,
                           delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction],
                           animations: { self.transform = .identity })
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            UIView.animate(withDuration: BearyMotion.animated(true) ? 0.13 : 0,
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
                separator.backgroundColor = BearyColors.line
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
