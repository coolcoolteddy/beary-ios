import UIKit

// ===== 设置页重组（2026-11-19 七组版）：新子页 =====
// 主题／语言／存储／数据用量／隐私／安全／通知各一页，
// 均走 BearySettingsSubpageViewController 壳（顶栏关闭＋居中标题＋滚动内容列）。
// 行样式与设置主页一致（卡内标题 12 灰、行上下 14、左右 16、行间 1px 线）。

// MARK: - 子页共用小件

/// 行按压视觉反馈（设置主页 settingsRowPressDown/Up 同款：只降透明度）。
final class BearySettingsRowPressTarget: NSObject {
    static let shared = BearySettingsRowPressTarget()
    @objc func pressDown(_ sender: UIButton) { sender.superview?.alpha = 0.55 }
    @objc func pressUp(_ sender: UIButton) { sender.superview?.alpha = 1 }
}

func bearySettingsRowChevron() -> UIImageView {
    let chevron = UIImageView(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 16))
    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.tintColor = BearyColors.gray
    chevron.contentMode = .scaleAspectFit
    NSLayoutConstraint.activate([
        chevron.widthAnchor.constraint(equalToConstant: 16),
        chevron.heightAnchor.constraint(equalToConstant: 16),
    ])
    return chevron
}

func bearySettingsRowSpacer() -> UIView {
    let spacer = UIView()
    spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
    return spacer
}

/// 可点行包容器（设置主页 makeSettingsTappableRow 同款：内容＋全幅透明按钮，
/// 点按只降透明度，不缩放整行）。
func bearySettingsTappableRow(content: UIView, button: UIButton) -> UIView {
    let wrap = UIView()
    wrap.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(content)
    button.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(button)
    button.addTarget(BearySettingsRowPressTarget.shared, action: #selector(BearySettingsRowPressTarget.pressDown(_:)), for: .touchDown)
    button.addTarget(BearySettingsRowPressTarget.shared, action: #selector(BearySettingsRowPressTarget.pressUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: wrap.topAnchor),
        content.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
        content.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
        content.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
        button.topAnchor.constraint(equalTo: wrap.topAnchor),
        button.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
        button.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
        button.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
    ])
    return wrap
}

/// 导航行内容（标题＋行尾文案＋右箭头），供各子页复用。
func bearySettingsNavContent(title: String, detail: String?) -> UIStackView {
    let titleLabel = UILabel()
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = BearyDynamicType.smallBodyFont()
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = BearyColors.ink
    titleLabel.numberOfLines = 0
    titleLabel.text = title
    titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    var parts: [UIView] = [titleLabel, bearySettingsRowSpacer()]
    if let detail = detail {
        let detailLabel = UILabel()
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = BearyColors.gray
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .right
        detailLabel.text = detail
        parts.append(detailLabel)
    }
    parts.append(bearySettingsRowChevron())
    let stack = UIStackView(arrangedSubviews: parts)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.spacing = 12
    stack.alignment = .center
    return stack
}

/// 开关行内容（标题＋说明＋开关），供各子页复用。
func bearySettingsSwitchContent(title: String, detail: String?, isOn: Bool, target: Any?, action: Selector) -> (row: UIStackView, toggle: UISwitch) {
    let titleLabel = UILabel()
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = BearyDynamicType.smallBodyFont()
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = BearyColors.ink
    titleLabel.numberOfLines = 0
    titleLabel.text = title
    var textParts: [UIView] = [titleLabel]
    if let detail = detail {
        let detailLabel = UILabel()
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = BearyColors.gray
        detailLabel.numberOfLines = 0
        detailLabel.text = detail
        textParts.append(detailLabel)
    }
    let textStack = UIStackView(arrangedSubviews: textParts)
    textStack.axis = .vertical
    textStack.spacing = 2
    textStack.alignment = .fill
    let toggle = UISwitch()
    toggle.isOn = isOn
    toggle.setContentHuggingPriority(.required, for: .horizontal)
    toggle.setContentCompressionResistancePriority(.required, for: .horizontal)
    if let target = target {
        toggle.addTarget(target, action: action, for: .valueChanged)
    }
    let row = UIStackView(arrangedSubviews: [textStack, toggle])
    row.translatesAutoresizingMaskIntoConstraints = false
    row.axis = .horizontal
    row.spacing = 12
    row.alignment = .center
    return (row, toggle)
}

/// 选项行内容（标题＋选中打勾），供主题／语言子页复用。
func bearySettingsOptionContent(title: String, isSelected: Bool) -> UIStackView {
    let titleLabel = UILabel()
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = BearyDynamicType.smallBodyFont()
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.textColor = BearyColors.ink
    titleLabel.numberOfLines = 0
    titleLabel.text = title
    titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    var parts: [UIView] = [titleLabel, bearySettingsRowSpacer()]
    if isSelected {
        let check = UIImageView(image: BearyIconImages.image(named: "icon_check", pointSize: 18))
        check.translatesAutoresizingMaskIntoConstraints = false
        check.tintColor = BearyColors.ink
        check.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([
            check.widthAnchor.constraint(equalToConstant: 18),
            check.heightAnchor.constraint(equalToConstant: 18),
        ])
        parts.append(check)
    }
    let stack = UIStackView(arrangedSubviews: parts)
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.spacing = 12
    stack.alignment = .center
    return stack
}

// MARK: - 主题子页

/// 主题：跟随系统开关默认开，关掉后下方出现浅色模式、深色模式两个选项。
/// 与旧三段滑块同款持久化与应用路径（beary_theme_mode + 窗口 override）。
final class BearyThemeSettingsViewController: BearySettingsSubpageViewController {
    init() { super.init(title: "主题") }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let followOn = BearyTheme.mode == "system"
        let (followRow, _) = bearySettingsSwitchContent(title: "跟随系统", detail: "跟随系统外观自动切换", isOn: followOn, target: self, action: #selector(followSwitchChanged(_:)))
        var rows: [UIView] = [followRow]
        if !followOn {
            let mode = BearyTheme.mode
            rows.append(bearySettingsTappableRow(content: bearySettingsOptionContent(title: "浅色模式", isSelected: mode == "light"), button: optionButton(action: #selector(lightTapped))))
            rows.append(bearySettingsTappableRow(content: bearySettingsOptionContent(title: "深色模式", isSelected: mode == "dark"), button: optionButton(action: #selector(darkTapped))))
        }
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: rows))
    }

    private func optionButton(action: Selector) -> UIButton {
        let button = UIButton(type: .custom)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func followSwitchChanged(_ sender: UISwitch) {
        if sender.isOn {
            BearyTheme.apply(mode: "system", window: view.window)
        } else {
            // 关掉跟随后默认落浅色（当前外观是深色时落深色，不闪变）。
            let fallback = traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            BearyTheme.apply(mode: fallback, window: view.window)
        }
        render()
    }

    @objc private func lightTapped() {
        BearyTheme.apply(mode: "light", window: view.window)
        render()
    }

    @objc private func darkTapped() {
        BearyTheme.apply(mode: "dark", window: view.window)
        render()
    }
}

// MARK: - 语言子页

/// 语言：跟随系统、中国大陆、English 三档；跟随系统即跟随系统语言，
/// 中国大陆即强制简体中文，English 即强制英文。切换即时生效（Bundle 覆盖＋重建根界面，
/// 见 BearyAppLanguage；SceneDelegate 监听广播重建）。
/// 注意：App 自身文案目前是硬编码中文（工程里没有 .xcstrings/.lproj，
/// 没有任何 NSLocalizedString 调用），切换对 App 自身界面暂无可见变化，
/// 只对走 Bundle 的第三方文案生效；English 档下已迁进 Catalog 的批显示英文，
/// 未迁移的批仍显示中文原文；完整切换须先做全站文案抽取，见 PR 说明。
final class BearyLanguageSettingsViewController: BearySettingsSubpageViewController {
    init() { super.init(title: "语言") }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let mode = BearyAppLanguage.mode
        let systemRow = bearySettingsTappableRow(content: bearySettingsOptionContent(title: "跟随系统", isSelected: mode == .system), button: optionButton(action: #selector(systemTapped)))
        let mainlandRow = bearySettingsTappableRow(content: bearySettingsOptionContent(title: "中国大陆", isSelected: mode == .mainland), button: optionButton(action: #selector(mainlandTapped)))
        let englishRow = bearySettingsTappableRow(content: bearySettingsOptionContent(title: "English", isSelected: mode == .english), button: optionButton(action: #selector(englishTapped)))
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: [systemRow, mainlandRow, englishRow]))
    }

    private func optionButton(action: Selector) -> UIButton {
        let button = UIButton(type: .custom)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func systemTapped() {
        BearyAppLanguage.setMode(.system)
        render()
    }

    @objc private func mainlandTapped() {
        BearyAppLanguage.setMode(.mainland)
        render()
    }

    @objc private func englishTapped() {
        BearyAppLanguage.setMode(.english)
        render()
    }
}

// MARK: - 管理存储页

/// 彩色存储条：四段按各分类占 App 总量的比例排布（X 管理存储页同款）。
private final class BearyStorageBarView: UIView {
    private var segments: [(color: UIColor, fraction: CGFloat)] = []

    func setSegments(_ segments: [(color: UIColor, fraction: CGFloat)]) {
        self.segments = segments
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        subviews.forEach { $0.removeFromSuperview() }
        guard bounds.width > 0 else { return }
        var x: CGFloat = 0
        for segment in segments where segment.fraction > 0 {
            let width = bounds.width * segment.fraction
            let view = UIView(frame: CGRect(x: x, y: 0, width: width, height: bounds.height))
            view.backgroundColor = segment.color
            addSubview(view)
            x += width
        }
    }
}

/// 管理存储：顶部“已使用 / 总容量”＋彩色存储条＋图例，下面带真实大小的行，
/// 最下面红色“清除所有存储”（点按有后果确认，清除真清对应缓存，
/// 草稿与日记数据不受影响）。
final class BearyStorageSettingsViewController: BearySettingsSubpageViewController {
    private var measurement: BearyStorageMeter.Measurement?
    private var isClearing = false

    init() { super.init(title: "管理存储") }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let measured = BearyStorageMeter.measure()
            DispatchQueue.main.async {
                self?.measurement = measured
                self?.render()
            }
        }
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let m = measurement
        let usedText = m.map { BearyStorageMeter.formatted(bytes: $0.appTotal) } ?? "–"
        let totalText = m.map { BearyStorageMeter.formatted(bytes: $0.deviceTotal) } ?? "–"
        let usedTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        usedTitle.text = "已使用"
        usedTitle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let usedValue = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink, lines: 0)
        usedValue.text = "\(usedText) / \(totalText)"
        usedValue.textAlignment = .right
        let usedRow = UIStackView(arrangedSubviews: [usedTitle, usedValue])
        usedRow.axis = .horizontal
        usedRow.spacing = 12
        usedRow.alignment = .center
        let bar = BearyStorageBarView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = BearyColors.surface2
        bar.layer.cornerRadius = 4
        bar.clipsToBounds = true
        NSLayoutConstraint.activate([bar.heightAnchor.constraint(equalToConstant: 8)])
        if let m = m, m.appTotal > 0 {
            let total = CGFloat(m.appTotal)
            bar.setSegments([
                (BearyColors.blue, CGFloat(m.media) / total),
                (BearyColors.green, CGFloat(m.network) / total),
                (BearyColors.orange, CGFloat(m.data) / total),
                (BearyColors.gray, CGFloat(m.other) / total),
            ])
        }
        let legend = legendRow(segments: [
            ("媒体存储", BearyColors.blue),
            ("网络缓存", BearyColors.green),
            ("数据", BearyColors.orange),
            ("其他", BearyColors.gray),
        ])
        let topStack = UIStackView(arrangedSubviews: [usedRow, bar, legend])
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topStack.axis = .vertical
        topStack.spacing = 12
        topStack.alignment = .fill
        let topCard = UIView()
        topCard.translatesAutoresizingMaskIntoConstraints = false
        topCard.backgroundColor = BearyColors.surface1
        topCard.layer.cornerRadius = BearyCorners.single
        topCard.clipsToBounds = true
        topCard.addSubview(topStack)
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: topCard.topAnchor, constant: 16),
            topStack.leadingAnchor.constraint(equalTo: topCard.leadingAnchor, constant: 16),
            topStack.trailingAnchor.constraint(equalTo: topCard.trailingAnchor, constant: -16),
            topStack.bottomAnchor.constraint(equalTo: topCard.bottomAnchor, constant: -16),
        ])
        contentStack.addArrangedSubview(topCard)
        let rows: [UIView] = [
            sizeRow(title: "媒体存储", sizeText: m.map { BearyStorageMeter.formatted(bytes: $0.media) } ?? "–"),
            sizeRow(title: "网络缓存", sizeText: m.map { BearyStorageMeter.formatted(bytes: $0.network) } ?? "–"),
            sizeRow(title: "数据", sizeText: m.map { BearyStorageMeter.formatted(bytes: $0.data) } ?? "–"),
            sizeRow(title: "其他", sizeText: m.map { BearyStorageMeter.formatted(bytes: $0.other) } ?? "–"),
        ]
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: rows))
        let clearButton = BearyHit44Button(type: .system)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setTitle("清除所有存储", for: .normal)
        clearButton.setTitleColor(BearyColors.destructiveText, for: .normal)
        clearButton.titleLabel?.font = BearyDynamicType.buttonSmallFont()
        clearButton.titleLabel?.adjustsFontForContentSizeCategory = true
        clearButton.layer.borderWidth = 1
        clearButton.layer.bearyDynamicBorderColor = BearyColors.alpha(BearyColors.destructiveText, 0.45)
        clearButton.layer.cornerRadius = 12
        clearButton.addTarget(self, action: #selector(clearButtonTapped), for: .touchUpInside)
        clearButton.bearyAddPressFeedback()
        clearButton.isEnabled = !isClearing && (m?.appTotal ?? 0) > 0
        clearButton.alpha = clearButton.isEnabled ? 1 : 0.5
        NSLayoutConstraint.activate([clearButton.heightAnchor.constraint(equalToConstant: 36)])
        contentStack.addArrangedSubview(clearButton)
    }

    private func legendRow(segments: [(title: String, color: UIColor)]) -> UIStackView {
        var items: [UIView] = []
        for segment in segments {
            let dot = UIView()
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.backgroundColor = segment.color
            dot.layer.cornerRadius = 4
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
            let label = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray)
            label.text = segment.title
            let item = UIStackView(arrangedSubviews: [dot, label])
            item.axis = .horizontal
            item.spacing = 6
            item.alignment = .center
            items.append(item)
        }
        let row = UIStackView(arrangedSubviews: items)
        row.axis = .horizontal
        row.spacing = 16
        row.alignment = .center
        row.distribution = .equalSpacing
        return row
    }

    private func sizeRow(title: String, sizeText: String) -> UIView {
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        titleLabel.text = title
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let sizeLabel = makeLabel(font: UIFont.systemFont(ofSize: 14), color: BearyColors.gray, lines: 0)
        sizeLabel.text = sizeText
        sizeLabel.textAlignment = .right
        let row = UIStackView(arrangedSubviews: [titleLabel, sizeLabel])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        return row
    }

    @objc private func clearButtonTapped() {
        guard !isClearing else { return }
        BearyConfirmSheet.show(from: self, title: "清除所有存储", message: "将清除图片、实况与网络缓存，草稿与日记数据不受影响。确定继续？", actions: [
            BearyConfirmSheet.Action(title: "清除", style: .destructive, handler: { [weak self] in
                self?.confirmClear()
            }),
        ])
    }

    private func confirmClear() {
        isClearing = true
        render()
        BearyStorageMeter.clearAllCaches { [weak self] measurement in
            guard let self = self else { return }
            self.isClearing = false
            self.measurement = measurement
            self.render()
        }
    }
}

// MARK: - 数据用量页

/// 数据用量：顶部一句说明，流量节省程序开关默认关，高画质图片行，
/// 自动播放实况开关。beary 没有视频功能，高画质视频／自动播放视频／
/// 1080p 视频上传／离线视频／网页存储一律不放。
final class BearyDataUsageSettingsViewController: BearySettingsSubpageViewController {
    init() { super.init(title: "数据用量") }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let introLabel = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        introLabel.text = "流量节省程序开启后，图片只加载缩略图，点开大图才加载原图；GIF 只显示第一帧，点一下才动。"
        contentStack.addArrangedSubview(introLabel)
        let saverOn = BearyDataSaver.isEnabled
        let (saverRow, _) = bearySettingsSwitchContent(title: "流量节省程序", detail: "启用后图片质量下降，实况照片不会自动播放", isOn: saverOn, target: self, action: #selector(saverSwitchChanged(_:)))
        let hiresDetail: String
        switch BearyHiResImagePolicy.current {
        case .cellularOrWifi: hiresDetail = "使用蜂窝或无线网络"
        case .wifiOnly: hiresDetail = "仅无线网络"
        case .off: hiresDetail = "关闭"
        }
        let hiresButton = UIButton(type: .custom)
        hiresButton.accessibilityLabel = "高画质图片"
        hiresButton.addTarget(self, action: #selector(hiresRowTapped), for: .touchUpInside)
        let hiresRow = bearySettingsTappableRow(content: bearySettingsNavContent(title: "高画质图片", detail: hiresDetail), button: hiresButton)
        let autoplayOn = BearyLivePhotoAutoplay.isEnabled
        let autoplayDetail = saverOn ? "流量节省程序开启时不自动播放" : "时间线和详情里的实况照片就绪后自动播放"
        let (autoplayRow, autoplaySwitch) = bearySettingsSwitchContent(title: "自动播放实况", detail: autoplayDetail, isOn: autoplayOn, target: self, action: #selector(autoplaySwitchChanged(_:)))
        autoplaySwitch.isEnabled = !saverOn
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: [saverRow, hiresRow, autoplayRow]))
    }

    @objc private func saverSwitchChanged(_ sender: UISwitch) {
        BearyDataSaver.setEnabled(sender.isOn)
        render()
    }

    @objc private func autoplaySwitchChanged(_ sender: UISwitch) {
        BearyLivePhotoAutoplay.setEnabled(sender.isOn)
    }

    @objc private func hiresRowTapped() {
        let current = BearyHiResImagePolicy.current
        let options: [(value: BearyHiResImagePolicy, title: String)] = [
            (.cellularOrWifi, "使用蜂窝或无线网络"),
            (.wifiOnly, "仅无线网络"),
            (.off, "关闭"),
        ]
        var actions: [BearyConfirmSheet.Action] = options.map { option in
            BearyConfirmSheet.Action(title: option.title, style: .default, handler: { [weak self] in
                BearyHiResImagePolicy.setCurrent(option.value)
                self?.render()
            }, isSelected: option.value == current)
        }
        BearyConfirmSheet.show(from: self, title: "高画质图片", message: "选择在什么网络下拉取原图", actions: actions)
    }
}

// MARK: - 隐私页

/// 隐私：隐私遮罩、自动获取定位、定位地址精度、自动获取天气、
/// 已拉黑用户、谁可以私信我。
final class BearyPrivacySettingsViewController: BearySettingsSubpageViewController {
    /// 私信档位行文案落点（GET／POST 回包后刷新）。
    private var dmDetailLabel: UILabel?
    private var dmRowButton: UIButton?
    private var dmLevel: String?
    private var dmLevelLoading = false
    private var dmLevelPosting = false
    private var dmLevelGeneration = 0
    private var dmLevelFetchGeneration = 0
    private var dmLevelPostGeneration = 0
    private var dmLevelRequestAccountId: Int?

    init() { super.init(title: "隐私") }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        refreshDMLevelRow()
        syncPrecisionFromServer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshDMLevelRow()
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let (maskRow, _) = bearySettingsSwitchContent(title: "隐私遮罩", detail: "在多任务切换界面中隐藏日记内容", isOn: BearyAppLockSettings.isMaskEnabled, target: self, action: #selector(maskSwitchChanged(_:)))
        let (autoLocationRow, _) = bearySettingsSwitchContent(title: "自动获取定位", detail: "写日记时自动获取当前位置", isOn: BearyAutoFetch.isLocationEnabled, target: self, action: #selector(autoLocationSwitchChanged(_:)))
        let precisionButton = UIButton(type: .custom)
        precisionButton.accessibilityLabel = "定位地址精度"
        precisionButton.addTarget(self, action: #selector(precisionRowTapped), for: .touchUpInside)
        let precisionRow = bearySettingsTappableRow(content: bearySettingsNavContent(title: "定位地址精度", detail: BearyLocationPrecision.current.title), button: precisionButton)
        let (autoWeatherRow, _) = bearySettingsSwitchContent(title: "自动获取天气", detail: "写日记时自动获取当地天气", isOn: BearyAutoFetch.isWeatherEnabled, target: self, action: #selector(autoWeatherSwitchChanged(_:)))
        let blockedButton = UIButton(type: .custom)
        blockedButton.accessibilityLabel = "已拉黑用户"
        blockedButton.addTarget(self, action: #selector(blockedRowTapped), for: .touchUpInside)
        let blockedRow = bearySettingsTappableRow(content: bearySettingsNavContent(title: "已拉黑用户", detail: nil), button: blockedButton)
        // 私信行：标题＋副标题“你关注的人始终可以给你发私信”，行尾当前档位。
        let dmTitle = UILabel()
        dmTitle.translatesAutoresizingMaskIntoConstraints = false
        dmTitle.font = BearyDynamicType.smallBodyFont()
        dmTitle.adjustsFontForContentSizeCategory = true
        dmTitle.textColor = BearyColors.ink
        dmTitle.numberOfLines = 0
        dmTitle.text = "谁可以私信我"
        let dmSubtitle = UILabel()
        dmSubtitle.translatesAutoresizingMaskIntoConstraints = false
        dmSubtitle.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        dmSubtitle.adjustsFontForContentSizeCategory = true
        dmSubtitle.textColor = BearyColors.gray
        dmSubtitle.numberOfLines = 0
        dmSubtitle.text = "你关注的人始终可以给你发私信"
        let dmTextStack = UIStackView(arrangedSubviews: [dmTitle, dmSubtitle])
        dmTextStack.axis = .vertical
        dmTextStack.spacing = 2
        dmTextStack.alignment = .fill
        let dmDetail = makeLabel(font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray, lines: 0)
        dmDetail.text = dmLevel.map { dmLevelText($0) } ?? "加载中…"
        dmDetailLabel = dmDetail
        let dmContent = UIStackView(arrangedSubviews: [dmTextStack, bearySettingsRowSpacer(), dmDetail, bearySettingsRowChevron()])
        dmContent.translatesAutoresizingMaskIntoConstraints = false
        dmContent.axis = .horizontal
        dmContent.spacing = 12
        dmContent.alignment = .center
        let dmButton = UIButton(type: .custom)
        dmButton.accessibilityLabel = "谁可以私信我"
        dmButton.addTarget(self, action: #selector(dmRowTapped), for: .touchUpInside)
        dmRowButton = dmButton
        let dmRow = bearySettingsTappableRow(content: dmContent, button: dmButton)
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: [maskRow, autoLocationRow, precisionRow, autoWeatherRow, blockedRow, dmRow]))
    }

    @objc private func maskSwitchChanged(_ sender: UISwitch) {
        BearyAppLockSettings.setMaskEnabled(sender.isOn)
    }

    @objc private func autoLocationSwitchChanged(_ sender: UISwitch) {
        BearyAutoFetch.setLocationEnabled(sender.isOn)
    }

    @objc private func autoWeatherSwitchChanged(_ sender: UISwitch) {
        BearyAutoFetch.setWeatherEnabled(sender.isOn)
    }

    @objc private func blockedRowTapped() {
        let vc = BearyBlockedUsersViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }

    // MARK: 定位地址精度

    @objc private func precisionRowTapped() {
        let current = BearyLocationPrecision.current
        var actions: [BearyConfirmSheet.Action] = BearyLocationPrecision.allCases.map { precision in
            BearyConfirmSheet.Action(title: precision.title, style: .default, handler: { [weak self] in
                BearyLocationPrecision.setCurrent(precision)
                self?.render()
            }, isSelected: precision == current)
        }
        BearyConfirmSheet.show(from: self, title: "定位地址精度", message: "国外按当地同级对应；精度由后端截断存储与展示，不只是本机显示", actions: actions)
    }

    /// 进页时从服务端同步一次精度（跨设备改过时以服务端为准；失败不报错、不覆盖本地）。
    private func syncPrecisionFromServer() {
        guard SessionManager.shared.isLoggedIn else { return }
        BearyAPI.shared.fetchLocationPrecision { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard case .success(let resp) = result,
                      let raw = resp.precision,
                      let server = BearyLocationPrecision(rawValue: raw),
                      server != BearyLocationPrecision.current else { return }
                UserDefaults.standard.set(server.rawValue, forKey: BearyLocationPrecision.key)
                self.render()
            }
        }
    }

    // MARK: 私信权限（三档新口径）

    private func dmLevelText(_ level: String) -> String {
        switch level {
        case "anyone": return "所有人"
        case "plus": return "Plus 用户"
        case "none": return "没有人"
        // 服务端部署前的旧档位：只作回显，不再提供选择；新档位保存后即被替换。
        case "followers": return "仅关注我的人"
        case "friends": return "仅好友"
        default: return NSLocalizedString("settings.dm.level_load_failed", comment: "")
        }
    }

    private func refreshDMLevelRow() {
        if let override = BearyDevPreviewState.dmLevelOverride {
            dmDetailLabel?.text = dmLevelText(override) + "（预览）"
            return
        }
        guard SessionManager.shared.isLoggedIn,
              let accountId = SessionManager.shared.currentUser?.id else { return }
        if dmLevelLoading, dmLevelRequestAccountId == accountId { return }
        dmLevelFetchGeneration += 1
        let fetchGeneration = dmLevelFetchGeneration
        let saveGeneration = dmLevelGeneration
        let epoch = BearyAPI.shared.authEpoch
        dmLevelRequestAccountId = accountId
        dmLevelLoading = true
        BearyAPI.shared.fetchDMLevel { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard fetchGeneration == self.dmLevelFetchGeneration,
                      accountId == SessionManager.shared.currentUser?.id,
                      epoch == BearyAPI.shared.authEpoch else { return }
                self.dmLevelLoading = false
                guard saveGeneration == self.dmLevelGeneration else { return }
                switch result {
                case .success(let resp):
                    if let level = resp.dmLevel {
                        self.dmLevel = level
                        self.dmDetailLabel?.text = self.dmLevelText(level)
                    }
                case .failure:
                    if self.dmLevel == nil {
                        self.dmDetailLabel?.text = NSLocalizedString("settings.dm.level_load_failed", comment: "")
                    }
                }
            }
        }
    }

    @objc private func dmRowTapped() {
        if BearyDevPreviewState.dmLevelOverride != nil {
            BearyToast.show(in: view, message: "预览态，档位切换已禁用")
            return
        }
        guard !dmLevelPosting else { return }
        let options: [(value: String, title: String)] = [
            ("none", "没有人"),
            ("plus", "Plus 用户"),
            ("anyone", "所有人"),
        ]
        var actions: [BearyConfirmSheet.Action] = options.map { option in
            BearyConfirmSheet.Action(title: option.title, style: .default, handler: { [weak self] in
                self?.saveDMLevel(option.value)
            }, isSelected: option.value == dmLevel)
        }
        BearyConfirmSheet.show(from: self, title: "谁可以私信我", message: "你关注的人始终可以给你发私信", actions: actions)
    }

    private func saveDMLevel(_ level: String) {
        guard level != dmLevel, !dmLevelPosting, SessionManager.shared.isLoggedIn,
              let accountId = SessionManager.shared.currentUser?.id else { return }
        dmLevelPostGeneration += 1
        let generation = dmLevelPostGeneration
        let epoch = BearyAPI.shared.authEpoch
        dmLevelPosting = true
        dmRowButton?.isEnabled = false
        let previousLevel = dmLevel
        dmLevel = level
        dmDetailLabel?.text = dmLevelText(level)
        dmLevelGeneration += 1
        BearyAPI.shared.saveDMLevel(level) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard generation == self.dmLevelPostGeneration,
                      accountId == SessionManager.shared.currentUser?.id,
                      epoch == BearyAPI.shared.authEpoch else { return }
                self.dmLevelPosting = false
                self.dmRowButton?.isEnabled = true
                switch result {
                case .success(let resp):
                    let saved = resp.dmLevel ?? level
                    self.dmLevel = saved
                    self.dmDetailLabel?.text = self.dmLevelText(saved)
                case .failure:
                    self.dmLevel = previousLevel
                    self.dmDetailLabel?.text = previousLevel.map { self.dmLevelText($0) } ?? NSLocalizedString("settings.dm.level_load_failed", comment: "")
                    self.playDenyShake()
                    BearyToast.show(in: self.view, message: "保存失败，请重试")
                }
            }
        }
    }

    /// 保存失败拒绝动效（摇头＋toast；震动由 BearyHaptics 走系统开关，不另加）。
    private func playDenyShake() {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, -6, 6, -4, 4, 0]
        animation.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        animation.duration = 0.3
        view.layer.add(animation, forKey: "bearyDenyShake")
    }
}

// MARK: - 安全页

/// 安全：邮箱验证码登录、登录设备、生物识别锁。
/// Passkey 之后会在本页加一行（未开工），本支不预留假行。
final class BearySecuritySettingsViewController: BearySettingsSubpageViewController {
    /// 设置页注入：已拉到的设备数据（nil = 还没取到，子页接共享加载）。
    var sessions: [BearyAccountSession]?
    var sessionsFailed = false
    var sessionsCountText: String?
    var sessionsLoad: BearySharedLoad<BearyAccountSessionsResponse>?
    /// 退出其他设备成功后，设置页重拉设备数。
    var onSessionsChanged: (() -> Void)?

    init() { super.init(title: "安全") }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 从设备页回来时经共享加载刷新设备数与列表（与设置页同一份在途
        // 结果共用；退出其他设备后设置页已 force 重拉，这里接同一份回包
        // 更新行尾；已有缓存时直接回缓存，不另发请求）。
        if let sharedLoad = sessionsLoad {
            sharedLoad.load { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    let list = resp.sessions ?? []
                    self.sessions = list
                    self.sessionsFailed = false
                    if let active = resp.activeCount {
                        self.sessionsCountText = "共 \(active) 台设备（活跃）"
                    } else {
                        self.sessionsCountText = "共 \(list.count) 台设备"
                    }
                case .failure:
                    self.sessionsFailed = true
                }
                self.render()
            }
        }
        render()
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let codeDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        codeDetail.text = "每次登录发送 6 位验证码，无需密码"
        let codeTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        codeTitle.font = BearyDynamicType.smallBodyFont()
        codeTitle.text = "邮箱验证码登录"
        let codeTextStack = UIStackView(arrangedSubviews: [codeTitle, codeDetail])
        codeTextStack.axis = .vertical
        codeTextStack.spacing = 2
        codeTextStack.alignment = .fill
        let codeRow = UIStackView(arrangedSubviews: [codeTextStack])
        codeRow.translatesAutoresizingMaskIntoConstraints = false
        codeRow.axis = .horizontal
        codeRow.spacing = 12
        codeRow.alignment = .center
        let deviceDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        deviceDetail.text = sessionsCountText
        let deviceTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        deviceTitle.font = BearyDynamicType.smallBodyFont()
        deviceTitle.text = "登录设备"
        let deviceTextStack = UIStackView(arrangedSubviews: [deviceTitle, deviceDetail])
        deviceTextStack.axis = .vertical
        deviceTextStack.spacing = 2
        deviceTextStack.alignment = .fill
        let deviceContent = UIStackView(arrangedSubviews: [deviceTextStack, bearySettingsRowSpacer(), bearySettingsRowChevron()])
        deviceContent.translatesAutoresizingMaskIntoConstraints = false
        deviceContent.axis = .horizontal
        deviceContent.spacing = 12
        deviceContent.alignment = .center
        let deviceButton = UIButton(type: .custom)
        deviceButton.accessibilityLabel = "登录设备"
        deviceButton.addTarget(self, action: #selector(devicesRowTapped), for: .touchUpInside)
        let deviceRow = bearySettingsTappableRow(content: deviceContent, button: deviceButton)
        // 生物识别锁（设置主页同款：开关默认关，未录入置灰并给原因；
        // 开启/关闭都要先验一次生物识别，验证失败开关视觉回滚）。
        let lockAvailability = BearyAppLockSettings.availability
        let lockTitle = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink)
        lockTitle.font = BearyDynamicType.smallBodyFont()
        lockTitle.text = "\(BearyAppLockSettings.biometryName)解锁"
        let lockDetail = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        lockDetail.text = lockAvailability.available ? BearyAppLockSettings.coldStartNote : (BearyAppLockSettings.isEnabled ? "已开启，当前设备未录入生物识别，重新启动 beary 时改用设备密码验证，点按开关可关闭" : (lockAvailability.reason ?? "此设备暂无法使用生物识别"))
        let lockTextStack = UIStackView(arrangedSubviews: [lockTitle, lockDetail])
        lockTextStack.axis = .vertical
        lockTextStack.spacing = 2
        lockTextStack.alignment = .fill
        let lockSwitch = UISwitch()
        lockSwitch.isOn = BearyAppLockSettings.isEnabled
        lockSwitch.isEnabled = lockAvailability.available || BearyAppLockSettings.isEnabled
        lockSwitch.setContentHuggingPriority(.required, for: .horizontal)
        lockSwitch.setContentCompressionResistancePriority(.required, for: .horizontal)
        lockSwitch.addTarget(self, action: #selector(lockSwitchChanged(_:)), for: .valueChanged)
        let lockRow = UIStackView(arrangedSubviews: [lockTextStack, lockSwitch])
        lockRow.translatesAutoresizingMaskIntoConstraints = false
        lockRow.axis = .horizontal
        lockRow.spacing = 12
        lockRow.alignment = .center
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: [codeRow, deviceRow, lockRow]))
    }

    @objc private func devicesRowTapped() {
        let vc = BearyDevicesViewController(
            sessions: sessions,
            failed: sessionsFailed,
            countText: sessionsCountText,
            sharedLoad: sessionsLoad)
        vc.onSessionsChanged = { [weak self] in self?.onSessionsChanged?() }
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        present(vc, animated: BearyMotion.animated(true))
    }

    @objc private func lockSwitchChanged(_ sender: UISwitch) {
        let desired = sender.isOn
        let name = BearyAppLockSettings.biometryName
        let verb = desired ? "开启" : "关闭"
        BearyAppLockSettings.evaluate(reason: "\(verb)\(name)解锁前请先验证") { [weak sender] success in
            guard let sender = sender else { return }
            if success {
                BearyAppLockSettings.setEnabled(desired)
                if !desired && !BearyAppLockSettings.availability.available {
                    sender.isEnabled = false
                }
            } else {
                sender.isOn = !desired
                BearyToast.show(in: self.view, message: "验证未通过，设置未更改")
            }
        }
    }
}

// MARK: - 通知子页

/// 通知：写日记提醒、限时日记到期、那年今日、留给明年的自己四个开关＋
/// 通知权限未开启提示（设置主页同款逻辑整段搬过来）。
final class BearyNotificationSettingsViewController: BearySettingsSubpageViewController {
    private var notificationSwitches: [BearyLocalNotifications.Kind: UISwitch] = [:]
    private var hintRow: UIView?

    init() { super.init(title: "通知") }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        render()
        refreshHintRow()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshHintRow()
    }

    private func render() {
        for view in contentStack.arrangedSubviews {
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let items: [(kind: BearyLocalNotifications.Kind, title: String, detail: String)] = [
            (.dailyReminder, BearyLocalNotifications.Kind.dailyReminder.title, NSLocalizedString("local_notifications.daily_reminder.detail", comment: "")),
            (.limitedExpiry, "限时日记到期", "限时结束、转回私密时提醒"),
            (.pastDay, BearyLocalNotifications.Kind.pastDay.title, NSLocalizedString("local_notifications.past_day.detail", comment: "")),
            (.pastSelfDelivery, "留给明年的自己", "留言送达当天早上 9:00（北京时间）提醒"),
            (.dmUnread, BearyLocalNotifications.Kind.dmUnread.title, NSLocalizedString("local_notifications.dm_unread.detail", comment: "")),
        ]
        var rows: [UIView] = []
        for (index, item) in items.enumerated() {
            let (row, toggle) = bearySettingsSwitchContent(title: item.title, detail: item.detail, isOn: BearyLocalNotifications.shared.isEnabled(item.kind), target: self, action: #selector(notificationSwitchChanged(_:)))
            toggle.tag = index
            toggle.accessibilityLabel = item.title
            notificationSwitches[item.kind] = toggle
            rows.append(row)
        }
        let hintButton = UIButton(type: .custom)
        hintButton.accessibilityLabel = "通知权限未开启，去系统设置里打开"
        hintButton.addTarget(self, action: #selector(hintTapped), for: .touchUpInside)
        let hintRowView = bearySettingsTappableRow(content: bearySettingsNavContent(title: "通知权限未开启", detail: "去系统设置里打开"), button: hintButton)
        hintRowView.isHidden = true
        hintRow = hintRowView
        rows.append(hintRowView)
        // 第 25 轮 59：广场有新日记的提醒不另设开关，纳入上面五类——任一类
        // 开着才发，五类全关即停；说明放组末行。
        let plazaNoteLabel = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        plazaNoteLabel.text = NSLocalizedString("local_notifications.plaza_note", comment: "")
        rows.append(plazaNoteLabel)
        contentStack.addArrangedSubview(makeGroupCard(title: nil, rows: rows))
    }

    @objc private func notificationSwitchChanged(_ sender: UISwitch) {
        let kinds = BearyLocalNotifications.Kind.allCases
        guard kinds.indices.contains(sender.tag) else { return }
        let kind = kinds[sender.tag]
        BearyLocalNotifications.shared.setEnabled(sender.isOn, for: kind)
        // 权限被拒时开关照常记偏好，只提示一次：进系统打开后即生效。
        if sender.isOn {
            BearyLocalNotifications.shared.fetchAuthorizationStatus { [weak self] status in
                switch status {
                case .notDetermined:
                    // 尚未询问授权时：用户主动开开关即发起授权（首次引导关掉后仍有入口）。
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        BearyLocalNotifications.shared.requestAuthorizationIfNeeded(force: true) {
                            BearyToast.show(in: self.view, message: "通知权限未开启，去系统设置里打开才生效")
                        }
                    }
                case .denied:
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        BearyToast.show(in: self.view, message: "通知权限未开启，去系统设置里打开才生效")
                    }
                default:
                    break
                }
            }
        }
    }

    @objc private func hintTapped() {
        BearyLocalNotifications.shared.openSystemSettings()
    }

    private func refreshHintRow() {
        BearyLocalNotifications.shared.fetchAuthorizationStatus { [weak self] status in
            DispatchQueue.main.async { [weak self] in
                guard let self, let hintRow = self.hintRow else { return }
                let showHint = (status == .denied)
                hintRow.isHidden = !showHint
                // makeGroupCard 把每行包在 wrap 里、分隔线是独立的 arrangedSubview，
                // 只藏行本身不塌高度：行高＋上下 14 留白与两条分隔线全留着，就是
                // 截图里「私信未读」与底部说明之间那块带线的空白。连同 wrap 与
                // 它前面一条分隔线一起藏，UIStackView 才会把整行塌掉；权限被拒
                // 时三处一起恢复，行回到原来的位置。
                if let wrap = hintRow.superview,
                   let stack = wrap.superview as? UIStackView,
                   let index = stack.arrangedSubviews.firstIndex(of: wrap) {
                    wrap.isHidden = !showHint
                    if index > 0 {
                        stack.arrangedSubviews[index - 1].isHidden = !showHint
                    }
                }
            }
        }
    }
}
