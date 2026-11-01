import UIKit
import CoreLocation
import MapKit

// ===== 编辑器定位气泡（批 E，2026-10-30；预览 v2 弹窗 + v3 搜索建议）=====
// 形态沿用心情/天气尖角弹出框的既有语言：框体贴工具栏上方、左右与工具栏同宽、
// 底边小尖角指向触发钮（框在工具栏上方，故尖角在框底、向下指钮；预览 HTML 把尖角画在
// 框顶是示意画法，真实编辑器里框顶尖角会指向空白，与心情/天气框的底尖角口径也不一致）。
// 行为：打开即自动定位（定位中确认钮禁用，防存空位置）；右边 ✅ 图标确认钮（官方 icon_check）+ 自己输入；
// ✅ 在自动定位态确认已定位地点，在自己输入态确认手动输入的地名（同一钮，不另起确认钮）；
// 长地名不得挤压右边两钮：状态文案横向抗压最低、两钮抗压/抱紧均为 required，✅ 固定 32×32。
// 自己输入边输边出 MapKit 搜索建议（MKLocalSearchCompleter），点建议直接定位；
// 权限被拒/定位失败不留空地点，走 delegate 失败口径（调用方 toast 后回未定位态）。
// 隐私：坐标只在内存里走一次逆地理编码取地名，用完即弃；本视图不写盘、不缓存坐标，
// 也不把坐标传给调用方——调用方只拿到 DiaryLocation（两段文本）。

protocol BearyLocationPopoverDelegate: AnyObject {
    func locationPopover(_ popover: BearyLocationPopoverView, didConfirm location: DiaryLocation)
    func locationPopoverDidFail(_ popover: BearyLocationPopoverView, message: String)
}

final class BearyLocationPopoverView: UIView, CLLocationManagerDelegate, MKLocalSearchCompleterDelegate {
    weak var delegate: BearyLocationPopoverDelegate?

    /// 尖角顶点在本视图坐标系的 x（调用方按定位钮中心设；布局时钳制在框内，
    /// 与 BearyCalloutPickerView.arrowCenterX 同口径）。
    var arrowCenterX: CGFloat = 0 {
        didSet {
            if arrowCenterX != oldValue { setNeedsLayout() }
        }
    }

    private static let arrowHeight: CGFloat = 10
    private static let arrowHalfWidth: CGFloat = 8
    private static let cornerRadius: CGFloat = 14

    private static var popoverBackgroundColor: UIColor {
        UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 38.0 / 255.0, green: 38.0 / 255.0, blue: 44.0 / 255.0, alpha: 1)
            }
            return UIColor(white: 0.96, alpha: 1)
        }
    }

    private let backgroundLayer = CAShapeLayer()
    private let mainStack = UIStackView()
    private let headerRow = UIStackView()
    private let spinner = BearyRefreshIconView()
    private let statusIconView = UIImageView()
    private let statusLabel = UILabel()
    private let confirmButton = BearyHit44Button(type: .system)
    private let manualButton = BearyHit44Button(type: .system)
    private let subLabel = UILabel()
    private let inputField = UITextField()
    // 审计 E2 第 6 项：建议区包进滚动视图——气泡总高不再随建议条数无上限长，
    // 头部、输入框保持原位，只有建议区内部滚动；选项仍是既有 5 条，不增不减。
    private let suggestionsScrollView = UIScrollView()
    private let suggestionsStack = UIStackView()
    private var suggestionsHeightConstraint: NSLayoutConstraint?
    private var popoverTopConstraint: NSLayoutConstraint?
    private var lastShadowSize: CGSize = .zero
    private let suggestionsEmptyLabel = UILabel()

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let completer = MKLocalSearchCompleter()
    private var suggestions: [MKLocalSearchCompletion] = []
    private var located: DiaryLocation?
    private var locating = false
    private var manualMode = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        layer.addSublayer(backgroundLayer)
        // 审计 E2 第 14 项：浮层阴影统一走轻薄单层 raised token（0.12/8/2），
        // 不再自写 0.15/8/2；阴影挂在本视图层（不裁剪），圆角裁剪由 shape path 负责。
        BearyShadow.applyRaised(to: backgroundLayer)

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.image = BearyLocationIcon.image(pointSize: 20)
        statusIconView.tintColor = BearyColors.gray
        statusIconView.contentMode = .scaleAspectFit
        statusIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusIconView.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.boldSystemFont(ofSize: 15)
        statusLabel.textColor = BearyColors.ink
        statusLabel.numberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        // 状态文案是唯一可压缩项：长地名先截断它，绝不挤压右边的 ✅ 与“自己输入”。
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.text = "正在获取当前位置…"

        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        // ✅ 按钮：官方 icon_check 资产（基线 Assets 在位，三档齐全），非文字“确认”；
        // 固定 32×32 橙色圆钮、白勾，横向抱紧/抗压均为 required，长地名也挤不动它。
        confirmButton.setImage(BearyIconImages.image(named: "icon_check", pointSize: 18), for: .normal)
        confirmButton.tintColor = BearyColors.onBrand
        confirmButton.backgroundColor = BearyColors.orange
        confirmButton.layer.cornerRadius = 16
        confirmButton.clipsToBounds = true
        confirmButton.accessibilityLabel = "确认使用这个位置"
        confirmButton.setContentHuggingPriority(.required, for: .horizontal)
        confirmButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        confirmButton.addTarget(self, action: #selector(didTapConfirm), for: .touchUpInside)
        manualButton.translatesAutoresizingMaskIntoConstraints = false
        manualButton.setTitle("自己输入", for: .normal)
        manualButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        manualButton.setTitleColor(BearyColors.ink, for: .normal)
        manualButton.layer.cornerRadius = 999
        manualButton.layer.borderWidth = 1
        manualButton.layer.bearyDynamicBorderColor = BearyColors.line
        manualButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        manualButton.setContentHuggingPriority(.required, for: .horizontal)
        manualButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        manualButton.accessibilityLabel = "自己输入地点"
        manualButton.addTarget(self, action: #selector(didTapManual), for: .touchUpInside)

        headerRow.axis = .horizontal
        headerRow.spacing = 10
        headerRow.alignment = .center
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.addArrangedSubview(spinner)
        headerRow.addArrangedSubview(statusIconView)
        headerRow.addArrangedSubview(statusLabel)
        headerRow.addArrangedSubview(confirmButton)
        headerRow.addArrangedSubview(manualButton)

        subLabel.translatesAutoresizingMaskIntoConstraints = false
        subLabel.font = UIFont.systemFont(ofSize: 12)
        subLabel.textColor = BearyColors.gray
        subLabel.numberOfLines = 0
        subLabel.text = "打开即自动定位，不用再点一次获取"

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.borderStyle = .roundedRect
        inputField.font = UIFont.systemFont(ofSize: 14)
        inputField.placeholder = "输入地点，例如：天一、月湖"
        inputField.clearButtonMode = .whileEditing
        inputField.isHidden = true
        inputField.addTarget(self, action: #selector(didChangeInput), for: .editingChanged)

        suggestionsEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        suggestionsEmptyLabel.font = UIFont.systemFont(ofSize: 13)
        suggestionsEmptyLabel.textColor = BearyColors.gray
        suggestionsEmptyLabel.text = "没有找到相关位置"
        suggestionsEmptyLabel.isHidden = true
        suggestionsStack.axis = .vertical
        suggestionsStack.spacing = 0
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionsScrollView.translatesAutoresizingMaskIntoConstraints = false
        suggestionsScrollView.addSubview(suggestionsStack)
        suggestionsScrollView.isHidden = true
        let suggestionsHeight = suggestionsScrollView.heightAnchor.constraint(equalToConstant: 0)
        suggestionsHeightConstraint = suggestionsHeight

        mainStack.axis = .vertical
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(headerRow)
        mainStack.addArrangedSubview(subLabel)
        mainStack.addArrangedSubview(inputField)
        mainStack.addArrangedSubview(suggestionsScrollView)
        addSubview(mainStack)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
            confirmButton.widthAnchor.constraint(equalToConstant: 32),
            confirmButton.heightAnchor.constraint(equalToConstant: 32),
            statusIconView.widthAnchor.constraint(equalToConstant: 20),
            statusIconView.heightAnchor.constraint(equalToConstant: 20),
            suggestionsStack.topAnchor.constraint(equalTo: suggestionsScrollView.contentLayoutGuide.topAnchor),
            suggestionsStack.leadingAnchor.constraint(equalTo: suggestionsScrollView.contentLayoutGuide.leadingAnchor),
            suggestionsStack.trailingAnchor.constraint(equalTo: suggestionsScrollView.contentLayoutGuide.trailingAnchor),
            suggestionsStack.bottomAnchor.constraint(equalTo: suggestionsScrollView.contentLayoutGuide.bottomAnchor),
            suggestionsStack.widthAnchor.constraint(equalTo: suggestionsScrollView.frameLayoutGuide.widthAnchor),
            suggestionsHeight,
            mainStack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            mainStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            mainStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            mainStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.arrowHeight - 12),
        ])
        setLocating()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // 审计 E2 第 6 项：气泡顶边不得顶出顶部安全区。调用方（Composer）只把
    // 气泡底贴工具栏顶，本文件内补一条顶边守卫：顶 ≥ 父视图安全区顶 + 8。
    // 主机制仍是建议区高度上限（见 updateSuggestionsHeight），本约束是兜底；
    // 优先级低于 required，避免极端尺寸下与调用方底约束死锁。
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        popoverTopConstraint?.isActive = false
        popoverTopConstraint = nil
        guard let superview = superview else { return }
        let top = topAnchor.constraint(greaterThanOrEqualTo: superview.safeAreaLayoutGuide.topAnchor, constant: 8)
        top.priority = .defaultHigh
        top.isActive = true
        popoverTopConstraint = top
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let boxHeight = max(0, bounds.height - Self.arrowHeight)
        backgroundLayer.frame = bounds
        let clampedX = min(max(arrowCenterX, Self.arrowHalfWidth + 4), max(width - Self.arrowHalfWidth - 4, Self.arrowHalfWidth + 4))
        let box = CGRect(x: 0, y: 0, width: width, height: boxHeight)
        let path = UIBezierPath(roundedRect: box, cornerRadius: Self.cornerRadius)
        path.move(to: CGPoint(x: clampedX - Self.arrowHalfWidth, y: boxHeight))
        path.addLine(to: CGPoint(x: clampedX, y: boxHeight + Self.arrowHeight))
        path.addLine(to: CGPoint(x: clampedX + Self.arrowHalfWidth, y: boxHeight))
        path.close()
        backgroundLayer.path = path.cgPath
        backgroundLayer.fillColor = Self.popoverBackgroundColor.resolvedColor(with: traitCollection).cgColor
        // 审计 E2 第 14 项：shadowPath 只在尺寸变化时更新，不逐帧重算。
        if bounds.size != lastShadowSize {
            lastShadowSize = bounds.size
            backgroundLayer.shadowPath = path.cgPath
        }
        updateSuggestionsHeight()
    }

    /// 审计 E2 第 6 项：建议区最大可用高度 = 气泡底（父视图坐标）到父视图
    /// 安全区顶之间，扣掉 16pt 余量与头部/副文案/输入框等固定部分；
    /// 至少留 88pt（约一条半建议），不足时建议区内部滚动、气泡不再顶出。
    /// 常量变化才写回，避免布局循环。未进父视图或未布局时不算（保持上次值）。
    private func updateSuggestionsHeight() {
        guard !suggestionsScrollView.isHidden,
              let heightConstraint = suggestionsHeightConstraint,
              let superview = superview, superview.bounds.height > 0, frame.maxY > 0, bounds.width > 0 else { return }
        suggestionsScrollView.layoutIfNeeded()
        let contentHeight = suggestionsStack.frame.height
        // 建议为空时高度归零（不留上一轮的空白区）；有内容时再按上限算。
        guard contentHeight > 0 else {
            if heightConstraint.constant != 0 { heightConstraint.constant = 0 }
            return
        }
        let fixedHeight = max(0, mainStack.frame.height - suggestionsScrollView.frame.height)
        let available = frame.maxY - superview.safeAreaInsets.top - 16 - fixedHeight
        let capped = min(contentHeight, max(88, available))
        if abs(heightConstraint.constant - capped) > 0.5 {
            heightConstraint.constant = capped
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            setNeedsLayout()
        }
    }

    // MARK: - 对外入口

    /// 打开即自动定位：每次打开都重新跑一遍，不复用上次结果（位置可能已变）。
    func startAutoLocate() {
        cancelRequests()
        located = nil
        setLocating()
        let status = CLLocationManager.authorizationStatus()
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locating = true
            locationManager.requestLocation()
        case .denied, .restricted:
            delegate?.locationPopoverDidFail(self, message: "定位权限未开启，请在“设置 → beary → 位置”中开启后重试")
        @unknown default:
            delegate?.locationPopoverDidFail(self, message: "定位失败，请重试或自己输入")
        }
    }

    /// 收起时停掉在途请求：定位/地理编码/搜索建议都不再回调，避免关弹窗后还弹结果。
    func cancelRequests() {
        locating = false
        locationManager.stopUpdatingLocation()
        geocoder.cancelGeocode()
        completer.queryFragment = ""
        spinner.stopSpinning()
    }

    // MARK: - 状态

    /// 审计 15 项第 14 项：内部状态切换的透明度过渡（约 0.16s 交叉淡入），
    /// 只过渡变化区域、不增加等待、不逐帧改约束；减动效时直接切换。
    private func fadeStateChange(_ changes: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            changes()
        } else {
            UIView.transition(with: mainStack, duration: 0.16, options: [.transitionCrossDissolve, .allowUserInteraction], animations: changes)
        }
    }

    private func setLocating() {
        fadeStateChange {
            self.manualMode = false
            self.locating = true
            self.spinner.isHidden = false
            self.spinner.startSpinning()
            self.statusIconView.isHidden = true
            self.statusLabel.text = "正在获取当前位置…"
            self.subLabel.text = "打开即自动定位，不用再点一次获取"
            self.setConfirmEnabled(false)
            self.inputField.isHidden = true
            self.suggestionsScrollView.isHidden = true
        }
    }

    private func setLocated(_ location: DiaryLocation) {
        fadeStateChange {
            self.manualMode = false
            self.locating = false
            self.located = location
            self.spinner.stopSpinning()
            self.spinner.isHidden = true
            self.statusIconView.isHidden = false
            self.statusLabel.text = location.name ?? location.district
            if let district = location.district, location.name != nil, district != location.name {
                self.subLabel.text = "已定位 · 公开后他人仅见区级（\(district)）"
            } else {
                self.subLabel.text = "已定位"
            }
            self.setConfirmEnabled(true)
            self.inputField.isHidden = true
            self.suggestionsScrollView.isHidden = true
        }
    }

    private func setManualMode(message: String? = nil) {
        fadeStateChange {
            self.manualMode = true
            self.locating = false
            self.spinner.stopSpinning()
            self.spinner.isHidden = true
            self.statusIconView.isHidden = false
            self.statusLabel.text = "自己输入地点"
            if let message = message {
                self.subLabel.text = message
            } else {
                self.subLabel.text = "输入地点，下方出现建议时点建议直接定位"
            }
            // 手动态的确认就是头部 ✅：有输入才可点，空输入禁用防误存；
            // 不再另起“使用这个地点”钮，避免两个确认入口。
            self.inputField.isHidden = false
            self.suggestionsScrollView.isHidden = false
            self.refreshManualConfirmState()
            self.inputField.becomeFirstResponder()
        }
    }

    private func setConfirmEnabled(_ enabled: Bool) {
        confirmButton.isEnabled = enabled
        confirmButton.alpha = enabled ? 1 : 0.4
    }

    private func refreshManualConfirmState() {
        // 仅手动态用：✅ 按输入有无置灰；自动定位态由 setLocating/setLocated 控 ✅，不走这里。
        guard manualMode else { return }
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        setConfirmEnabled(!text.isEmpty)
    }

    // MARK: - 点按

    @objc private func didTapConfirm() {
        // 手动态：✅ 确认手动输入的地名（区级仍由地理编码得出，不由用户手填）。
        if manualMode {
            didConfirmManualText()
            return
        }
        guard let location = located, !location.isEmpty else { return }
        delegate?.locationPopover(self, didConfirm: location)
    }

    @objc private func didTapManual() {
        cancelRequests()
        setManualMode()
    }

    @objc private func didChangeInput() {
        refreshManualConfirmState()
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            clearSuggestions()
            return
        }
        completer.queryFragment = text
    }

    private func didConfirmManualText() {
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // 手动输入的区级仍由地理编码得出，不由用户手填（v2 口径）；编不到区级时
        // district 留空——他人视角展示层 fail-closed（不显示），不拿精确名冒充区级。
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        MKLocalSearch(request: request).start { [weak self] response, _ in
            guard let self = self, !self.isHidden else { return }
            let district = response?.mapItems.first.map { BearyLocationDisplay.district(from: $0.placemark) } ?? nil
            self.delegate?.locationPopover(self, didConfirm: DiaryLocation(name: text, district: district))
        }
    }

    @objc private func didTapSuggestion(_ sender: UIButton) {
        let index = sender.tag
        guard index < suggestions.count else { return }
        let completion = suggestions[index]
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { [weak self] response, _ in
            guard let self = self, !self.isHidden else { return }
            let placemark = response?.mapItems.first?.placemark
            let name = placemark?.name ?? completion.title
            // flatMap 把 String?? 压到一层 String?，与 DiaryLocation(district:) 入参对齐；
            // 无 placemark 或无区级时均为 nil，不改逆地理编码流程。
            let district = placemark.flatMap { BearyLocationDisplay.district(from: $0) }
            // 点建议即直接定位：不等头部确认钮，调用方直接落定该地点（v3 口径）。
            self.delegate?.locationPopover(self, didConfirm: DiaryLocation(name: name, district: district))
        }
    }

    /// 只清旧视图，不动结果数据：正常渲染先清旧按钮/旧空态，再按当前 suggestions 重建。
    /// 此前 renderSuggestions 首句调 clearSuggestions，而后者首句就把 suggestions 置空，
    /// 导致 completerDidUpdateResults 刚赋值的 completer.results 立即被清空、
    /// suggestions.isEmpty 恒真、有结果也永远走“没有找到”空态分支。
    private func clearSuggestionViews() {
        for sub in suggestionsStack.arrangedSubviews {
            suggestionsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        suggestionsEmptyLabel.isHidden = true
    }

    /// 全清：数据 + 视图。仅输入清空或搜索失败（且输入已空）等“旧建议必须不残留”时用；
    /// 正常渲染不得走这里，否则会把刚到的结果清掉。
    private func clearSuggestions() {
        suggestions = []
        clearSuggestionViews()
    }

    private func renderSuggestions() {
        clearSuggestionViews()
        // 布局一轮后按内容高与可用高重算建议区上限（见 updateSuggestionsHeight；
        // layoutSubviews 也会再算一次，首帧不靠它也能落定）。
        layoutIfNeeded()
        updateSuggestionsHeight()
        if suggestions.isEmpty {
            suggestionsStack.addArrangedSubview(suggestionsEmptyLabel)
            suggestionsEmptyLabel.isHidden = false
            return
        }
        for (index, item) in suggestions.prefix(5).enumerated() {
            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = index
            button.contentHorizontalAlignment = .left
            button.titleLabel?.numberOfLines = 0
            let title = NSMutableAttributedString(
                string: item.title,
                attributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: BearyColors.ink]
            )
            if !item.subtitle.isEmpty {
                title.append(NSAttributedString(
                    string: "\n\(item.subtitle)",
                    attributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: BearyColors.gray]
                ))
            }
            button.setAttributedTitle(title, for: .normal)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 2, bottom: 10, right: 2)
            button.accessibilityLabel = "定位到\(item.title)"
            button.addTarget(self, action: #selector(didTapSuggestion(_:)), for: .touchUpInside)
            suggestionsStack.addArrangedSubview(button)
        }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locating else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            delegate?.locationPopoverDidFail(self, message: "定位权限未开启，请在“设置 → beary → 位置”中开启后重试")
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locating, let coordinate = locations.last else { return }
        locating = false
        // 坐标只进这一次逆地理编码，取地名后即弃，不存、不传、不缓存。
        geocoder.reverseGeocodeLocation(coordinate) { [weak self] placemarks, _ in
            // 气泡已关（isHidden）时在途回调一律丢弃：不转手动态、不弹键盘、不落定。
            guard let self = self, !self.isHidden else { return }
            guard let placemark = placemarks?.first else {
                // 逆地理编码失败：不持久化“已定位（暂未解析地名）”这类占位文本，
                // 直接转手动输入，让用户 typed 的地名成为真实位置值。
                self.setManualMode(message: "未能解析当前位置地名，请自己输入")
                return
            }
            let name = placemark.name ?? [placemark.thoroughfare, placemark.subThoroughfare].compactMap { $0 }.joined(separator: "")
            let location = DiaryLocation(name: name.isEmpty ? nil : name, district: BearyLocationDisplay.district(from: placemark))
            if location.isEmpty {
                self.setManualMode(message: "未能解析当前位置地名，请自己输入")
            } else {
                self.setLocated(location)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard locating else { return }
        locating = false
        delegate?.locationPopoverDidFail(self, message: "定位失败，请重试或自己输入")
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        guard !isHidden else { return }
        // 扫荡 D：输入已清空后，旧查询的建议回包仍会到达——此时若照常渲染，
        // 空输入框下方会冒出与当前输入无关的旧建议。输入为空时直接清掉，不渲染。
        // （@ 选人搜索有序号守卫，旧回包会被丢弃；本气泡的 completer 回包此前无此守卫。）
        guard !(inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSuggestions()
            return
        }
        suggestions = completer.results
        renderSuggestions()
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        // 扫荡 D：与上同口径——气泡已关或输入已空时不把“没有找到相关位置”
        // 写进建议栈，否则下次打开手动态会先看到一条过期空态。
        guard !isHidden else { return }
        guard !(inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clearSuggestions()
            return
        }
        suggestions = []
        renderSuggestions()
    }
}
