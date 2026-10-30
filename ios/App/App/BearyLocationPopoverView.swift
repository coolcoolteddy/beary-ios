import UIKit
import CoreLocation
import MapKit

// ===== 编辑器定位气泡（批 E，2026-10-30；预览 v2 弹窗 + v3 搜索建议）=====
// 形态沿用心情/天气尖角弹出框的既有语言：框体贴工具栏上方、左右与工具栏同宽、
// 底边小尖角指向触发钮（框在工具栏上方，故尖角在框底、向下指钮；预览 HTML 把尖角画在
// 框顶是示意画法，真实编辑器里框顶尖角会指向空白，与心情/天气框的底尖角口径也不一致）。
// 行为：打开即自动定位（定位中确认钮禁用，防存空位置）；右边 ✓ 确认 + 自己输入；
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
    private let confirmButton = UIButton(type: .system)
    private let manualButton = UIButton(type: .system)
    private let subLabel = UILabel()
    private let inputField = UITextField()
    private let useManualRow = UIStackView()
    private let useManualButton = UIButton(type: .system)
    private let suggestionsStack = UIStackView()
    private let suggestionsEmptyLabel = UILabel()

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private let completer = MKLocalSearchCompleter()
    private var suggestions: [MKLocalSearchCompletion] = []
    private var located: DiaryLocation?
    private var locating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.clear
        layer.addSublayer(backgroundLayer)
        backgroundLayer.shadowColor = UIColor.black.cgColor
        backgroundLayer.shadowOpacity = 0.15
        backgroundLayer.shadowRadius = 8
        backgroundLayer.shadowOffset = CGSize(width: 0, height: 2)

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]

        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.image = BearyLocationIcon.image(pointSize: 20)
        statusIconView.tintColor = BearyColors.gray
        statusIconView.contentMode = .scaleAspectFit
        statusIconView.isHidden = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.boldSystemFont(ofSize: 15)
        statusLabel.textColor = BearyColors.ink
        statusLabel.numberOfLines = 2
        statusLabel.text = "正在获取当前位置…"

        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.setTitle("确认", for: .normal)
        confirmButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        confirmButton.backgroundColor = BearyColors.orange
        confirmButton.setTitleColor(.white, for: .normal)
        confirmButton.layer.cornerRadius = 999
        confirmButton.clipsToBounds = true
        confirmButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        confirmButton.accessibilityLabel = "确认使用这个位置"
        confirmButton.addTarget(self, action: #selector(didTapConfirm), for: .touchUpInside)
        manualButton.translatesAutoresizingMaskIntoConstraints = false
        manualButton.setTitle("自己输入", for: .normal)
        manualButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        manualButton.setTitleColor(BearyColors.ink, for: .normal)
        manualButton.layer.cornerRadius = 999
        manualButton.layer.borderWidth = 1
        manualButton.layer.borderColor = BearyColors.line.cgColor
        manualButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
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

        useManualButton.translatesAutoresizingMaskIntoConstraints = false
        useManualButton.setTitle("使用这个地点", for: .normal)
        useManualButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13)
        useManualButton.backgroundColor = BearyColors.orange
        useManualButton.setTitleColor(.white, for: .normal)
        useManualButton.layer.cornerRadius = 999
        useManualButton.clipsToBounds = true
        useManualButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)
        useManualButton.accessibilityLabel = "使用输入的地点"
        useManualButton.addTarget(self, action: #selector(didTapUseManual), for: .touchUpInside)
        let useSpacer = UIView()
        useManualRow.axis = .horizontal
        useManualRow.translatesAutoresizingMaskIntoConstraints = false
        useManualRow.addArrangedSubview(useSpacer)
        useManualRow.addArrangedSubview(useManualButton)
        useManualRow.isHidden = true

        suggestionsEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        suggestionsEmptyLabel.font = UIFont.systemFont(ofSize: 13)
        suggestionsEmptyLabel.textColor = BearyColors.gray
        suggestionsEmptyLabel.text = "没有找到相关位置"
        suggestionsEmptyLabel.isHidden = true
        suggestionsStack.axis = .vertical
        suggestionsStack.spacing = 0
        suggestionsStack.translatesAutoresizingMaskIntoConstraints = false
        suggestionsStack.isHidden = true

        mainStack.axis = .vertical
        mainStack.spacing = 10
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(headerRow)
        mainStack.addArrangedSubview(subLabel)
        mainStack.addArrangedSubview(inputField)
        mainStack.addArrangedSubview(useManualRow)
        mainStack.addArrangedSubview(suggestionsStack)
        addSubview(mainStack)
        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 20),
            spinner.heightAnchor.constraint(equalToConstant: 20),
            statusIconView.widthAnchor.constraint(equalToConstant: 20),
            statusIconView.heightAnchor.constraint(equalToConstant: 20),
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

    private func setLocating() {
        locating = true
        spinner.isHidden = false
        spinner.startSpinning()
        statusIconView.isHidden = true
        statusLabel.text = "正在获取当前位置…"
        subLabel.text = "打开即自动定位，不用再点一次获取"
        setConfirmEnabled(false)
        inputField.isHidden = true
        useManualRow.isHidden = true
        suggestionsStack.isHidden = true
    }

    private func setLocated(_ location: DiaryLocation) {
        locating = false
        located = location
        spinner.stopSpinning()
        spinner.isHidden = true
        statusIconView.isHidden = false
        statusLabel.text = location.name ?? location.district
        if let district = location.district, location.name != nil, district != location.name {
            subLabel.text = "已定位 · 公开后他人仅见区级（\(district)）"
        } else {
            subLabel.text = "已定位"
        }
        setConfirmEnabled(true)
        inputField.isHidden = true
        useManualRow.isHidden = true
        suggestionsStack.isHidden = true
    }

    private func setManualMode(message: String? = nil) {
        locating = false
        spinner.stopSpinning()
        spinner.isHidden = true
        statusIconView.isHidden = false
        statusLabel.text = "自己输入地点"
        if let message = message {
            subLabel.text = message
        } else {
            subLabel.text = "输入地点，下方出现建议时点建议直接定位"
        }
        // 手动态的确认走“使用这个地点”；头部的确认钮只对应已定位态，手动态禁用防误存。
        setConfirmEnabled(false)
        inputField.isHidden = false
        useManualRow.isHidden = false
        suggestionsStack.isHidden = false
        refreshManualConfirmState()
        inputField.becomeFirstResponder()
    }

    private func setConfirmEnabled(_ enabled: Bool) {
        confirmButton.isEnabled = enabled
        confirmButton.alpha = enabled ? 1 : 0.4
    }

    private func refreshManualConfirmState() {
        let text = (inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        useManualButton.isEnabled = !text.isEmpty
        useManualButton.alpha = text.isEmpty ? 0.4 : 1
    }

    // MARK: - 点按

    @objc private func didTapConfirm() {
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

    @objc private func didTapUseManual() {
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
            let district = placemark.map { BearyLocationDisplay.district(from: $0) }
            // 点建议即直接定位：不等头部确认钮，调用方直接落定该地点（v3 口径）。
            self.delegate?.locationPopover(self, didConfirm: DiaryLocation(name: name, district: district))
        }
    }

    private func clearSuggestions() {
        suggestions = []
        for sub in suggestionsStack.arrangedSubviews {
            suggestionsStack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }
        suggestionsEmptyLabel.isHidden = true
    }

    private func renderSuggestions() {
        clearSuggestions()
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
        suggestions = completer.results
        renderSuggestions()
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
        renderSuggestions()
    }
}
