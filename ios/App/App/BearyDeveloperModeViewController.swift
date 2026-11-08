// 开发者模式页（2026-11-08 新增）：
// 入口只有设置页底部版本号连点 5 次（见 BearySettingsViewController.versionFooterTapped），
// 平时完全看不见。页内全部控制只改内存预览态（BearyDevPreviewState），
// 不写本地库、不上云，退出开发者模式即清掉（见 BearyDeveloperMode.exit）。
// 总开关关掉时本页自动关闭；网络模拟只拦请求不改数据，重启 App 自动关。

import UIKit
import UserNotifications

final class BearyDeveloperModeViewController: BearySettingsSubpageViewController {

    init() {
        super.init(title: "开发者模式")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let note = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
        note.text = "以下全部只放内存预览，不写本地库、不上云；退出开发者模式即清掉。时间旅行只改显示，写操作一律走真实日期。"
        contentStack.addArrangedSubview(note)

        contentStack.addArrangedSubview(makeGroupCard(title: "开发者模式", rows: [
            switchRow(title: "开发者模式", isOn: BearyDeveloperMode.shared.isEnabled) { [weak self] isOn in
                guard let self = self else { return }
                if isOn {
                    BearyDeveloperMode.shared.setEnabled(true, window: self.view.window)
                } else {
                    BearyDeveloperMode.shared.exit(window: self.view.window)
                    self.dismiss(animated: true)
                }
            },
        ]))

        var notificationRows: [UIView] = []
        for kind in BearyLocalNotifications.Kind.allCases {
            notificationRows.append(buttonRow(title: kind.title) { [weak self] in
                self?.fireNotificationTest(kind: kind)
            })
        }
        contentStack.addArrangedSubview(makeGroupCard(title: "通知测试", rows: notificationRows))

        contentStack.addArrangedSubview(makeGroupCard(title: "那年今日", rows: [
            switchRow(title: "假数据预览", detail: "模拟往年今日有日记", isOn: BearyDevPreviewState.pastDayPreview) { isOn in
                BearyDevPreviewState.pastDayPreview = isOn
                BearyDeveloperMode.shared.postChange(kind: "preview")
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "过去的自己", rows: [
            switchRow(title: "模拟送达卡", detail: "模拟明年今日的留话送达", isOn: BearyDevPreviewState.pastSelfDeliveryPreview) { isOn in
                BearyDevPreviewState.pastSelfDeliveryPreview = isOn
                BearyDeveloperMode.shared.postChange(kind: "preview")
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "限时日记", rows: [
            switchRow(title: "模拟到期态", detail: "限时日记按已到期显示", isOn: BearyDevPreviewState.forceLimitedExpired) { isOn in
                BearyDevPreviewState.forceLimitedExpired = isOn
                BearyDeveloperMode.shared.postChange(kind: "preview")
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "改日期（时间旅行）", rows: [
            datePickerRow(),
            actionRow(title: "回到今天") { [weak self] in
                BearyDevPreviewState.fakeDay = nil
                BearyDeveloperMode.shared.postChange(kind: "date")
                self?.resetDatePicker()
                BearyToast.show(in: self?.view ?? UIView(), message: "已回到今天")
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "网络模拟", rows: [
            segmentedRow(
                title: "请求模拟",
                options: ["正常", "断网", "弱网 2.5s", "接口 500"],
                selected: networkSimulationIndex()
            ) { index in
                switch index {
                case 1: BearyDevPreviewState.networkSimulation = .offline
                case 2: BearyDevPreviewState.networkSimulation = .slow
                case 3: BearyDevPreviewState.networkSimulation = .serverError
                default: BearyDevPreviewState.networkSimulation = .normal
                }
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "空态、报错态预览", rows: [
            segmentedRow(title: "时间线", options: ["无", "空", "错", "加载"], selected: forcedIndex(BearyDevPreviewState.forcedTimeline)) { index in
                BearyDevPreviewState.forcedTimeline = Self.forcedState(index)
                BearyDeveloperMode.shared.postChange(kind: "forcedTimeline")
            },
            segmentedRow(title: "回收站", options: ["无", "空", "错", "加载"], selected: forcedIndex(BearyDevPreviewState.forcedTrash)) { index in
                BearyDevPreviewState.forcedTrash = Self.forcedState(index)
                BearyDeveloperMode.shared.postChange(kind: "forcedTrash")
            },
            segmentedRow(title: "搜索", options: ["无", "空", "错", "加载"], selected: forcedIndex(BearyDevPreviewState.forcedSearch)) { index in
                BearyDevPreviewState.forcedSearch = Self.forcedState(index)
                BearyDeveloperMode.shared.postChange(kind: "forcedSearch")
            },
            segmentedRow(title: "地图", options: ["无", "空", "错", "加载"], selected: forcedIndex(BearyDevPreviewState.forcedMap)) { index in
                BearyDevPreviewState.forcedMap = Self.forcedState(index)
                BearyDeveloperMode.shared.postChange(kind: "forcedMap")
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "大字号", rows: [
            switchRow(title: "大字号", detail: "走动态字号入口的字放大 1.3 倍", isOn: BearyDevPreviewState.fontScale > 1.0) { isOn in
                BearyDevPreviewState.fontScale = isOn ? 1.3 : 1.0
                BearyDeveloperMode.shared.postChange(kind: "font")
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "深浅色", rows: [
            segmentedRow(title: "外观", options: ["跟随系统", "浅色", "深色"], selected: appearanceIndex()) { [weak self] index in
                let style: UIUserInterfaceStyle = index == 1 ? .light : (index == 2 ? .dark : .unspecified)
                BearyDeveloperMode.shared.applyAppearance(style, on: self?.view.window)
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "账号、关系速切", rows: [
            switchRow(title: "游客预览", detail: "已登录时也能复现游客门控", isOn: BearyDevPreviewState.guestPreview) { isOn in
                BearyDevPreviewState.guestPreview = isOn
                BearyDeveloperMode.shared.postChange(kind: "account")
            },
            segmentedRow(title: "关注态", options: ["默认", "未关注", "已关注", "被关注", "互关"], selected: followStateIndex()) { index in
                BearyDevPreviewState.followStateOverride = index == 0 ? nil : index - 1
                BearyDeveloperMode.shared.postChange(kind: "account")
            },
            segmentedRow(title: "谁可以私信我", options: ["默认", "所有人", "仅关注我", "仅好友", "任何人不可"], selected: dmLevelIndex()) { index in
                switch index {
                case 1: BearyDevPreviewState.dmLevelOverride = "anyone"
                case 2: BearyDevPreviewState.dmLevelOverride = "followers"
                case 3: BearyDevPreviewState.dmLevelOverride = "friends"
                case 4: BearyDevPreviewState.dmLevelOverride = "none"
                default: BearyDevPreviewState.dmLevelOverride = nil
                }
                BearyDeveloperMode.shared.postChange(kind: "account")
            },
            segmentedRow(title: "对方允许私信", options: ["默认", "允许", "不允许"], selected: dmCanIndex()) { index in
                BearyDevPreviewState.dmCanOverride = index == 0 ? nil : (index == 1)
                BearyDeveloperMode.shared.postChange(kind: "account")
            },
        ]))

        contentStack.addArrangedSubview(makeGroupCard(title: "列表滑动", rows: [
            switchRow(title: "塞 1000 篇假日记", detail: "时间线与广场首屏换成假日记", isOn: BearyDevPreviewState.fakeEntriesEnabled) { isOn in
                BearyDevPreviewState.fakeEntriesEnabled = isOn
                BearyDeveloperMode.shared.postChange(kind: "fakeEntries")
            },
        ]))
    }

    // MARK: - 行

    private var datePicker: UIDatePicker?

    private func switchRow(title: String, detail: String? = nil, isOn: Bool, onChange: @escaping (Bool) -> Void) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink, lines: 0)
        titleLabel.text = title
        textStack.addArrangedSubview(titleLabel)
        if let detail = detail {
            let detailLabel = makeLabel(font: UIFont.systemFont(ofSize: 12), color: BearyColors.gray, lines: 0)
            detailLabel.text = detail
            textStack.addArrangedSubview(detailLabel)
        }
        row.addArrangedSubview(textStack)
        let spacer = UIView()
        row.addArrangedSubview(spacer)
        let toggle = UISwitch()
        toggle.isOn = isOn
        // 闭包弱引控件：UIAction 被控件持有，强引会造成控件自循环泄漏。
        toggle.addAction(UIAction { [weak toggle] _ in
            guard let toggle = toggle else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        row.addArrangedSubview(toggle)
        return row
    }

    private func buttonRow(title: String, onTap: @escaping () -> Void) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink, lines: 0)
        titleLabel.text = title
        row.addArrangedSubview(titleLabel)
        let spacer = UIView()
        row.addArrangedSubview(spacer)
        let button = UIButton(type: .system)
        button.setTitle("发送", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.setTitleColor(BearyColors.orange, for: .normal)
        button.addAction(UIAction { _ in onTap() }, for: .touchUpInside)
        row.addArrangedSubview(button)
        return row
    }

    /// 整行操作按钮（文案即按钮，如“回到今天”）。
    private func actionRow(title: String, onTap: @escaping () -> Void) -> UIView {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        button.setTitleColor(BearyColors.orange, for: .normal)
        button.contentHorizontalAlignment = .left
        button.addAction(UIAction { _ in onTap() }, for: .touchUpInside)
        return button
    }

    private func segmentedRow(title: String, options: [String], selected: Int, onChange: @escaping (Int) -> Void) -> UIView {
        let row = UIStackView()
        row.axis = .vertical
        row.alignment = .fill
        row.spacing = 8
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink, lines: 0)
        titleLabel.text = title
        row.addArrangedSubview(titleLabel)
        let segmented = UISegmentedControl(items: options)
        segmented.selectedSegmentIndex = selected
        // 闭包弱引控件：UIAction 被控件持有，强引会造成控件自循环泄漏。
        segmented.addAction(UIAction { [weak segmented] _ in
            guard let segmented = segmented else { return }
            onChange(segmented.selectedSegmentIndex)
        }, for: .valueChanged)
        row.addArrangedSubview(segmented)
        return row
    }

    private func datePickerRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        let titleLabel = makeLabel(font: UIFont.systemFont(ofSize: 15), color: BearyColors.ink, lines: 0)
        titleLabel.text = "今天"
        row.addArrangedSubview(titleLabel)
        let spacer = UIView()
        row.addArrangedSubview(spacer)
        let picker = UIDatePicker()
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .compact
        picker.locale = Locale(identifier: "zh_CN")
        picker.timeZone = TimeZone(identifier: "Asia/Shanghai")
        picker.date = BearyDevPreviewState.fakeTodayDate() ?? Date()
        // 闭包弱引控件：UIAction 被控件持有，强引会造成控件自循环泄漏。
        picker.addAction(UIAction { [weak self, weak picker] _ in
            guard let self = self, let picker = picker else { return }
            let components = BearyBeijingDay.calendar.dateComponents([.year, .month, .day], from: picker.date)
            guard let year = components.year, let month = components.month, let day = components.day else { return }
            BearyDevPreviewState.fakeDay = (year: year, month: month, day: day)
            BearyDeveloperMode.shared.postChange(kind: "date")
        }, for: .valueChanged)
        datePicker = picker
        row.addArrangedSubview(picker)
        return row
    }

    private func resetDatePicker() {
        datePicker?.date = Date()
    }

    // MARK: - 初始选中

    private func networkSimulationIndex() -> Int {
        switch BearyDevPreviewState.networkSimulation {
        case .offline: return 1
        case .slow: return 2
        case .serverError: return 3
        case .normal: return 0
        }
    }

    private static func forcedState(_ index: Int) -> BearyDevPreviewState.ForcedState {
        switch index {
        case 1: return .empty
        case 2: return .error
        case 3: return .loading
        default: return .none
        }
    }

    private func forcedIndex(_ state: BearyDevPreviewState.ForcedState) -> Int {
        switch state {
        case .empty: return 1
        case .error: return 2
        case .loading: return 3
        case .none: return 0
        }
    }

    private func appearanceIndex() -> Int {
        // 深浅色不持久化：进页时按进开发者模式时记下的窗口外观取初值
        //（viewDidLoad 时 view.window 尚为 nil，读不到窗口样式）。
        switch BearyDeveloperMode.shared.appearanceStyle {
        case .light: return 1
        case .dark: return 2
        default: return 0
        }
    }

    private func followStateIndex() -> Int {
        guard let override = BearyDevPreviewState.followStateOverride else { return 0 }
        return override + 1
    }

    private func dmLevelIndex() -> Int {
        switch BearyDevPreviewState.dmLevelOverride {
        case "anyone": return 1
        case "followers": return 2
        case "friends": return 3
        case "none": return 4
        default: return 0
        }
    }

    private func dmCanIndex() -> Int {
        switch BearyDevPreviewState.dmCanOverride {
        case true: return 1
        case false: return 2
        default: return 0
        }
    }

    // MARK: - 通知测试

    private func fireNotificationTest(kind: BearyLocalNotifications.Kind) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                    BearyToast.show(in: self.view, message: "通知权限未开启，去系统设置里打开")
                    return
                }
                BearyLocalNotifications.shared.testFire(kind: kind)
                BearyToast.show(in: self.view, message: "已发送「\(kind.title)」测试通知")
            }
        }
    }
}
