import UIKit
import MessageUI
import PhotosUI
import UniformTypeIdentifiers
import Darwin

// ===== 反馈与改进（2026-10-28 反馈 v3，路线 A：不做后端，走邮件附件）=====
// 界面按 v4 预览（与 v3 差异仅底部）：子页全屏 modal + fadeRise，左上文字
// 「关闭」15pt 墨字、标题 17；顶部状态行「反馈数据已准备就绪」+ beary 绿勾；
// 问题描述区：系统 UISegmentedControl（问题反馈 / 优化建议，选中段墨底 +
// 反色字，既定样式，不自造分段控件）+ 编辑器正文同款 UITextView；图片或视频
// （可选，最多 5 个）添加卡（手绘 icon_image）；设备信息卡 8 行；底部依次为
// 墨底主钮「提交反馈」、secondaryOutline「分享诊断日志」（手绘 icon_share）、
// 「诊断」分组 + secondaryOutline「仅上传日志」、footnote。
// 组件规矩（2026-10-28 Li 定，长期有效）：组件一律走 iOS 系统组件
// （UIButton / UITextView / PHPicker / MFMailCompose / UIActivityViewController），
// 图标只用手绘官方包（icon_image、icon_share 均取 89 包 xcassets；资产缺失时
// 只显示文字，不自绘、不混 SF Symbol 做主图标，系统组件自带的除外）。
// 部署目标 iOS 15.0、Swift 5.0：只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 设备信息（卡片 9 行与 device-info.txt 同值）

enum BearyFeedbackDeviceInfo {
    static func rows() -> [(key: String, value: String)] {
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let batteryState = device.batteryState
        let batteryLevel = device.batteryLevel
        device.isBatteryMonitoringEnabled = wasMonitoring
        let batteryStateText: String
        switch batteryState {
        case .charging:
            batteryStateText = "充电中"
        case .full:
            batteryStateText = "已充满"
        case .unplugged:
            batteryStateText = "未充电"
        default:
            batteryStateText = "未知"
        }
        let batteryLevelText: String
        if batteryLevel < 0 {
            batteryLevelText = "未知"
        } else {
            batteryLevelText = "\(Int(round(batteryLevel * 100)))%"
        }
        let memoryText = String(format: "%.2f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000_000.0)
        let diskText: String
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = attrs[.systemFreeSize] as? NSNumber {
            diskText = String(format: "%.1f GB", free.doubleValue / 1_000_000_000.0)
        } else {
            diskText = "未知"
        }
        let appVersionShort = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let appVersionBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        // 补缺 P3-34：设备信息补构建号（设置页脚注同款两值）；补缺 P3-35：设备名称行删除（用户自定名称进附件属隐私）。
        let appVersion = "\(appVersionShort)（构建号 \(appVersionBuild)）"
        return [
            ("设备型号", machineIdentifier()),
            ("系统名称", device.systemName),
            ("系统版本", device.systemVersion),
            ("应用版本", appVersion),
            ("电池状态", batteryStateText),
            ("电池电量", batteryLevelText),
            ("总内存", memoryText),
            ("可用磁盘空间", diskText),
        ]
    }

    static func text() -> String {
        return rows().map { "\($0.key)：\($0.value)" }.joined(separator: "\n")
    }

    private static func machineIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return UIDevice.current.model }
        var machine = [CChar](repeating: 0, count: size)
        let result = sysctlbyname("hw.machine", &machine, &size, nil, 0)
        guard result == 0 else { return UIDevice.current.model }
        return machine.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return UIDevice.current.model }
            return String(cString: base)
        }
    }
}

// MARK: - 最小 zip（stored 条目，不引新依赖）

/// zip 选择（2026-10-28 汇报用）：工程已有 SPM 但只接了 Lottie；为这一个
/// 功能新增 ZIPFoundation 远端依赖会给每次 CI 构建加一次远端拉取与版本解析，
/// 且 zip 内容很小（日志上限 1MB + 设备信息 + 诊断日志 200 行），stored 条目
/// 足够；故不用 Compression 的 deflate（ZIP 要 raw deflate，Compression 给的
/// 是 zlib 包裹格式，剥头剥尾易碎），也不引新库，手写 stored zip（本地头 +
/// 中央目录 + 结束记录，CRC32 表驱动，ASCII 文件名，macOS 解包器可读）。
enum BearyZipBuilder {
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            table[i] = c
        }
        return table
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func append16(_ value: UInt16, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    private static func append32(_ value: UInt32, to data: inout Data) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    /// files：(文件名，内容)。文件名须 ASCII 且单文件 < 4GB（日志包远小于此）。
    static func build(files: [(name: String, data: Data)]) -> Data? {
        guard files.count < 65536 else { return nil }
        var out = Data()
        var central = Data()
        var offset: UInt32 = 0
        for file in files {
            guard let nameData = file.name.data(using: .utf8),
                  nameData.count < 65536,
                  file.data.count <= Int(UInt32.max) else { return nil }
            let crc = crc32(file.data)
            let size = UInt32(file.data.count)
            var local = Data()
            append32(0x04034b50, to: &local)
            append16(20, to: &local)
            append16(0, to: &local)
            append16(0, to: &local)
            append16(0, to: &local)
            append16(0, to: &local)
            append32(crc, to: &local)
            append32(size, to: &local)
            append32(size, to: &local)
            append16(UInt16(nameData.count), to: &local)
            append16(0, to: &local)
            local.append(nameData)
            local.append(file.data)
            append32(0x02014b50, to: &central)
            append16(20, to: &central)
            append16(20, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(crc, to: &central)
            append32(size, to: &central)
            append32(size, to: &central)
            append16(UInt16(nameData.count), to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append16(0, to: &central)
            append32(0, to: &central)
            append32(offset, to: &central)
            central.append(nameData)
            out.append(local)
            offset += UInt32(local.count)
        }
        let centralSize = UInt32(central.count)
        let centralOffset = offset
        out.append(central)
        append32(0x06054b50, to: &out)
        append16(0, to: &out)
        append16(0, to: &out)
        append16(UInt16(files.count), to: &out)
        append16(UInt16(files.count), to: &out)
        append32(centralSize, to: &out)
        append32(centralOffset, to: &out)
        append16(0, to: &out)
        return out
    }
}

// MARK: - 反馈页

final class BearyFeedbackViewController: UIViewController, UITextViewDelegate, PHPickerViewControllerDelegate, MFMailComposeViewControllerDelegate {

    private enum PendingMailKind {
        case submit
        case logOnly
    }

    private struct Attachment {
        let data: Data
        let mimeType: String
        let fileName: String
    }

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let statusLabel = UILabel()
    private let statusBadge = UIView()
    private let typeSegmented = UISegmentedControl(items: ["问题反馈", "优化建议"])
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let attachLabelButton = UIButton(type: .custom)
    private let attachClearButton = UIButton(type: .system)
    private let submitButton = BearyButton.make(style: .primaryPill(.ink), title: "提交反馈")
    private let shareButton = BearyButton.make(style: .secondaryOutline(.regular), title: "分享诊断日志")
    private let logOnlyButton = BearyButton.make(style: .secondaryOutline(.regular), title: "仅上传日志")

    private var attachments: [Attachment] = []
    private var zipURL: URL?
    private var zipReady = false
    private var pendingMailKind: PendingMailKind = .submit

    private static let recipient = "hi@teddyhn.com"
    private static let descriptionPlaceholder = "请描述遇到的问题：在哪个页面、做了什么操作、看到了什么…"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.faint
        BearyAppLog.event("feedback open")
        buildChrome()
        buildContent()
        updateSubmitEnabled()
        refreshAttachUI()
        generateZip { [weak self] url in
            guard let self = self else { return }
            if let urlValue = url {
                self.zipURL = urlValue
                self.zipReady = true
                self.statusLabel.text = "反馈数据已准备就绪"
                self.statusBadge.isHidden = false
            } else {
                self.zipReady = false
                self.statusLabel.text = "反馈数据准备失败"
                self.statusBadge.isHidden = true
                BearyAppLog.event("feedback zip failed")
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        cleanupZip()
    }

    // MARK: - 顶栏（诊断页同款：52 高、左上文字关闭 15、标题 17 居中）

    private func buildChrome() {
        let closeButton = BearyHit44Button(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()

        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .bold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.textAlignment = .center
        titleLabel.text = "反馈与改进"

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = BearyColors.faint
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        view.addSubview(topBar)
        // 补缺 P2-17：顶栏与内容列同宽居中（详情页同款：iPhone 全宽减 32，iPad 600 居中）。
        let topBarWidthEquality = topBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        topBarWidthEquality.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            topBarWidthEquality,
            topBar.heightAnchor.constraint(equalToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .onDrag
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)
        // 补缺 P2-17：iPad 600 居中（详情页同款，含 750 宽度等式防短内容压塌）。
        let contentWidthEquality = contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        contentWidthEquality.priority = UILayoutPriority(750)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 12),
            contentStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            contentWidthEquality,
        ])
    }

    // MARK: - 内容（自上而下：状态卡 → 描述 → 附件 → 设备 → 提交 → 分享 → 诊断 → footnote）

    private func buildContent() {
        let statusCard = makeCard()
        let statusRow = UIStackView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        statusLabel.textColor = BearyColors.ink
        statusLabel.text = "反馈数据准备中…"
        // 补缺 P3-34：绿勾走官方包 icon_check，不用“✓”文本。
        let badgeCheck = UIImageView(image: BearyIconImages.image(named: "icon_check", pointSize: 16))
        badgeCheck.translatesAutoresizingMaskIntoConstraints = false
        badgeCheck.tintColor = .white
        badgeCheck.contentMode = .scaleAspectFit
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.backgroundColor = BearyColors.green
        statusBadge.layer.cornerRadius = 13
        statusBadge.clipsToBounds = true
        statusBadge.isHidden = true
        statusBadge.addSubview(badgeCheck)
        NSLayoutConstraint.activate([
            statusBadge.widthAnchor.constraint(equalToConstant: 26),
            statusBadge.heightAnchor.constraint(equalToConstant: 26),
            badgeCheck.centerXAnchor.constraint(equalTo: statusBadge.centerXAnchor),
            badgeCheck.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),
            badgeCheck.widthAnchor.constraint(equalToConstant: 16),
            badgeCheck.heightAnchor.constraint(equalToConstant: 16),
        ])
        statusRow.addArrangedSubview(statusLabel)
        statusRow.addArrangedSubview(UIView())
        statusRow.addArrangedSubview(statusBadge)
        statusCard.addSubview(statusRow)
        NSLayoutConstraint.activate([
            statusRow.topAnchor.constraint(equalTo: statusCard.topAnchor, constant: 14),
            statusRow.leadingAnchor.constraint(equalTo: statusCard.leadingAnchor, constant: 14),
            statusRow.trailingAnchor.constraint(equalTo: statusCard.trailingAnchor, constant: -14),
            statusRow.bottomAnchor.constraint(equalTo: statusCard.bottomAnchor, constant: -14),
        ])

        let descLabel = makeSectionLabel("问题描述")
        let descCard = makeCard()
        typeSegmented.translatesAutoresizingMaskIntoConstraints = false
        typeSegmented.selectedSegmentIndex = 0
        typeSegmented.selectedSegmentTintColor = BearyColors.ink
        typeSegmented.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 15)], for: .normal)
        typeSegmented.setTitleTextAttributes([.font: UIFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: BearyColors.bg], for: .selected)
        let textContainer = UIView()
        textContainer.translatesAutoresizingMaskIntoConstraints = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.delegate = self
        textView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = BearyColors.ink
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = UIFont.systemFont(ofSize: 16)
        placeholderLabel.textColor = BearyColors.gray
        placeholderLabel.numberOfLines = 0
        placeholderLabel.text = Self.descriptionPlaceholder
        textContainer.addSubview(textView)
        textContainer.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: textContainer.topAnchor),
            textView.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: textContainer.bottomAnchor),
            placeholderLabel.topAnchor.constraint(equalTo: textContainer.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: textContainer.leadingAnchor),
            placeholderLabel.trailingAnchor.constraint(equalTo: textContainer.trailingAnchor),
        ])
        let descInner = UIStackView(arrangedSubviews: [typeSegmented, textContainer])
        descInner.translatesAutoresizingMaskIntoConstraints = false
        descInner.axis = .vertical
        descInner.spacing = 12
        descCard.addSubview(descInner)
        NSLayoutConstraint.activate([
            typeSegmented.heightAnchor.constraint(equalToConstant: 36),
            textContainer.heightAnchor.constraint(equalToConstant: 160),
            descInner.topAnchor.constraint(equalTo: descCard.topAnchor, constant: 12),
            descInner.leadingAnchor.constraint(equalTo: descCard.leadingAnchor, constant: 12),
            descInner.trailingAnchor.constraint(equalTo: descCard.trailingAnchor, constant: -12),
            descInner.bottomAnchor.constraint(equalTo: descCard.bottomAnchor, constant: -12),
        ])

        let mediaLabel = makeSectionLabel("图片或视频（可选，最多 5 个）")
        let attachCard = makeCard()
        attachLabelButton.translatesAutoresizingMaskIntoConstraints = false
        attachLabelButton.setTitle("添加图片或视频", for: .normal)
        attachLabelButton.setTitleColor(BearyColors.ink, for: .normal)
        attachLabelButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        if let attachIcon = BearyIconImages.image(named: "icon_image", pointSize: 18) {
            attachLabelButton.setImage(attachIcon, for: .normal)
        }
        attachLabelButton.tintColor = BearyColors.gray
        attachLabelButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        attachLabelButton.accessibilityLabel = "添加图片或视频"
        attachLabelButton.addTarget(self, action: #selector(pickTapped), for: .touchUpInside)
        attachLabelButton.bearyAddPressFeedback()
        attachClearButton.translatesAutoresizingMaskIntoConstraints = false
        attachClearButton.setTitle("清除", for: .normal)
        attachClearButton.setTitleColor(BearyColors.gray, for: .normal)
        attachClearButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        attachClearButton.accessibilityLabel = "清除已选附件"
        attachClearButton.addTarget(self, action: #selector(clearAttachmentsTapped), for: .touchUpInside)
        attachClearButton.bearyAddPressFeedback()
        attachClearButton.isHidden = true
        let attachRow = UIStackView(arrangedSubviews: [attachLabelButton, attachClearButton])
        attachRow.translatesAutoresizingMaskIntoConstraints = false
        attachRow.axis = .horizontal
        attachRow.alignment = .center
        attachRow.spacing = 8
        attachCard.addSubview(attachRow)
        NSLayoutConstraint.activate([
            attachRow.topAnchor.constraint(equalTo: attachCard.topAnchor, constant: 8),
            attachRow.leadingAnchor.constraint(equalTo: attachCard.leadingAnchor, constant: 14),
            attachRow.trailingAnchor.constraint(equalTo: attachCard.trailingAnchor, constant: -14),
            attachRow.bottomAnchor.constraint(equalTo: attachCard.bottomAnchor, constant: -8),
            attachLabelButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        let deviceLabel = makeSectionLabel("设备信息")
        let deviceCard = makeCard()
        let deviceStack = UIStackView()
        deviceStack.translatesAutoresizingMaskIntoConstraints = false
        deviceStack.axis = .vertical
        deviceStack.spacing = 0
        let deviceRows = BearyFeedbackDeviceInfo.rows()
        for (index, row) in deviceRows.enumerated() {
            let keyLabel = UILabel()
            keyLabel.translatesAutoresizingMaskIntoConstraints = false
            keyLabel.font = UIFont.systemFont(ofSize: 15)
            keyLabel.textColor = BearyColors.gray
            keyLabel.text = row.key
            let valueLabel = UILabel()
            valueLabel.translatesAutoresizingMaskIntoConstraints = false
            valueLabel.font = UIFont.systemFont(ofSize: 15)
            valueLabel.textColor = BearyColors.ink
            valueLabel.textAlignment = .right
            valueLabel.text = row.value
            let kvRow = UIStackView(arrangedSubviews: [keyLabel, valueLabel])
            kvRow.translatesAutoresizingMaskIntoConstraints = false
            kvRow.axis = .horizontal
            kvRow.alignment = .center
            deviceStack.addArrangedSubview(kvRow)
            NSLayoutConstraint.activate([
                kvRow.heightAnchor.constraint(equalToConstant: 42),
            ])
            if index < deviceRows.count - 1 {
                let separator = UIView()
                separator.translatesAutoresizingMaskIntoConstraints = false
                separator.backgroundColor = BearyColors.line
                deviceStack.addArrangedSubview(separator)
                NSLayoutConstraint.activate([
                    separator.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
        }
        deviceCard.addSubview(deviceStack)
        NSLayoutConstraint.activate([
            deviceStack.topAnchor.constraint(equalTo: deviceCard.topAnchor),
            deviceStack.leadingAnchor.constraint(equalTo: deviceCard.leadingAnchor, constant: 14),
            deviceStack.trailingAnchor.constraint(equalTo: deviceCard.trailingAnchor, constant: -14),
            deviceStack.bottomAnchor.constraint(equalTo: deviceCard.bottomAnchor),
        ])

        submitButton.translatesAutoresizingMaskIntoConstraints = false
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.bearyAddPressFeedback()
        shareButton.translatesAutoresizingMaskIntoConstraints = false
        if let shareIcon = BearyIconImages.image(named: "icon_share", pointSize: 18) {
            shareButton.setImage(shareIcon, for: .normal)
        }
        shareButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        shareButton.bearyAddPressFeedback()
        let diagLabel = makeSectionLabel("诊断")
        logOnlyButton.translatesAutoresizingMaskIntoConstraints = false
        logOnlyButton.addTarget(self, action: #selector(logOnlyTapped), for: .touchUpInside)
        logOnlyButton.bearyAddPressFeedback()

        let footnote = UILabel()
        footnote.translatesAutoresizingMaskIntoConstraints = false
        footnote.font = UIFont.systemFont(ofSize: 13)
        footnote.textColor = BearyColors.gray
        footnote.numberOfLines = 0
        footnote.text = "发送走邮件到 hi@teddyhn.com；未配邮箱时复制文字内容，附件不随复制发出；分享诊断日志走系统分享表，只发日志包，不含描述与附件；仅上传日志只发日志包。"

        let views: [UIView] = [statusCard, descLabel, descCard, mediaLabel, attachCard, deviceLabel, deviceCard, submitButton, shareButton, diagLabel, logOnlyButton, footnote]
        for viewItem in views {
            contentStack.addArrangedSubview(viewItem)
        }
        contentStack.setCustomSpacing(18, after: statusCard)
        contentStack.setCustomSpacing(8, after: descLabel)
        contentStack.setCustomSpacing(18, after: descCard)
        contentStack.setCustomSpacing(8, after: mediaLabel)
        contentStack.setCustomSpacing(18, after: attachCard)
        contentStack.setCustomSpacing(8, after: deviceLabel)
        contentStack.setCustomSpacing(20, after: deviceCard)
        contentStack.setCustomSpacing(12, after: submitButton)
        contentStack.setCustomSpacing(18, after: shareButton)
        contentStack.setCustomSpacing(8, after: diagLabel)
        contentStack.setCustomSpacing(16, after: logOnlyButton)
        NSLayoutConstraint.activate([
            submitButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.ink).height),
            shareButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.regular).height),
            logOnlyButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.regular).height),
        ])
    }

    private func makeCard() -> UIView {
        let card = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = BearyColors.surface
        card.layer.cornerRadius = 12
        card.clipsToBounds = true
        return card
    }

    private func makeSectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 13)
        label.textColor = BearyColors.gray
        label.text = text
        return label
    }

    private func updateSubmitEnabled() {
        let hasText = !textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        submitButton.isEnabled = hasText
        submitButton.alpha = hasText ? 1.0 : 0.4
    }

    private func refreshAttachUI() {
        if attachments.isEmpty {
            attachLabelButton.setTitle("添加图片或视频", for: .normal)
            attachLabelButton.accessibilityLabel = "添加图片或视频"
            attachClearButton.isHidden = true
        } else {
            attachLabelButton.setTitle("已选 \(attachments.count) 个 · 点按重选", for: .normal)
            attachLabelButton.accessibilityLabel = "已选 \(attachments.count) 个，点按重选"
            attachClearButton.isHidden = false
        }
    }

    private func deviceInfoText() -> String {
        return BearyFeedbackDeviceInfo.text()
    }

    private func typePrefix() -> String {
        return typeSegmented.selectedSegmentIndex == 1 ? "[优化建议]" : "[问题反馈]"
    }

    private func submitBodyText() -> String {
        let description = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return description + "\n\n--- 设备信息 ---\n" + deviceInfoText()
    }

    // MARK: - zip 生成（进页时生成一次；分享 / 仅上传日志按需重生成）

    private func generateZip(completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let infoData = BearyFeedbackDeviceInfo.text().data(using: .utf8) ?? Data()
            var files: [(name: String, data: Data)] = [("device-info.txt", infoData)]
            if let appData = BearyAppLog.readData() {
                files.append(("beary-app.log", appData))
            }
            if let diagData = try? Data(contentsOf: DiagFile.url) {
                files.append(("beary-diag.log", diagData))
            }
            guard let zipData = BearyZipBuilder.build(files: files) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("beary-feedback-logs.zip")
            do {
                try zipData.write(to: url, options: .atomic)
                DispatchQueue.main.async { completion(url) }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    /// 补缺 P3-34：tmp zip 清理（发送/分享完成与页面关闭时删；文件已删则 zipReady 视为失效，下次 ensureZip 重生成）。
    private func cleanupZip() {
        if let url = zipURL {
            try? FileManager.default.removeItem(at: url)
        }
        zipURL = nil
        zipReady = false
    }

    private func ensureZip(completion: @escaping (Bool) -> Void) {
        if zipReady, let url = zipURL, FileManager.default.fileExists(atPath: url.path) {
            completion(true)
            return
        }
        zipReady = false
        generateZip { [weak self] url in
            guard let self = self else { return }
            if let urlValue = url {
                self.zipURL = urlValue
                self.zipReady = true
                self.statusLabel.text = "反馈数据已准备就绪"
                self.statusBadge.isHidden = false
                completion(true)
            } else {
                self.zipReady = false
                self.statusLabel.text = "反馈数据准备失败"
                self.statusBadge.isHidden = true
                BearyAppLog.event("feedback zip failed")
                completion(false)
            }
        }
    }

    // MARK: - 操作

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    @objc private func pickTapped() {
        var config = PHPickerConfiguration()
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 5
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: BearyMotion.animated(true))
    }

    @objc private func clearAttachmentsTapped() {
        attachments = []
        refreshAttachUI()
    }

    @objc private func submitTapped() {
        let description = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            BearyToast.show(in: view, message: "请先填写问题描述", aboveFAB: false)
            BearyHaptics.rejectionWarning()
            return
        }
        pendingMailKind = .submit
        if zipReady {
            presentMailComposer()
        } else {
            // 清理后二次提交先重生成（不直接判失败）；重生成失败才走无 zip 发送。
            ensureZip { [weak self] ready in
                guard let self = self else { return }
                if ready {
                    self.presentMailComposer()
                } else {
                    // zip 缺失时发送仍可继续（不带 zip）：先 toast 明说，待 toast 可见
                    // 后再弹出邮件撰写框，避免撰写框盖住 toast 导致说明不可见。
                    BearyToast.show(in: self.view, message: "日志包准备失败，本次反馈不含日志包", aboveFAB: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { [weak self] in
                        guard let self = self, self.presentedViewController == nil else { return }
                        self.presentMailComposer()
                    }
                }
            }
        }
    }

    @objc private func shareTapped() {
        ensureZip { [weak self] ready in
            guard let self = self else { return }
            guard ready, let url = self.zipURL else {
                BearyToast.show(in: self.view, message: "日志包准备失败", aboveFAB: false)
                BearyHaptics.rejectionWarning()
                return
            }
            // 分享内容只含日志包 zip 一个文件，不含描述与图片 / 视频。
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = self.shareButton
            sheet.popoverPresentationController?.sourceRect = self.shareButton.bounds
            sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                BearyAppLog.event(completed ? "feedback share completed" : "feedback share cancelled")
                self?.cleanupZip()
            }
            self.present(sheet, animated: BearyMotion.animated(true))
        }
    }

    @objc private func logOnlyTapped() {
        ensureZip { [weak self] ready in
            guard let self = self else { return }
            guard ready else {
                BearyToast.show(in: self.view, message: "日志包准备失败", aboveFAB: false)
                BearyHaptics.rejectionWarning()
                return
            }
            self.pendingMailKind = .logOnly
            if MFMailComposeViewController.canSendMail() {
                self.presentLogOnlyComposer()
            } else {
                // 仅上传日志无文字可复制，不走复制 fallback：toast 明说两条出路。
                BearyToast.show(in: self.view, message: "请先配置邮箱，或改用“分享诊断日志”", aboveFAB: false)
                BearyHaptics.rejectionWarning()
            }
        }
    }

    // MARK: - 邮件（系统 MFMailCompose；未配邮箱时按种类分流）

    private func presentMailComposer() {
        guard MFMailComposeViewController.canSendMail() else {
            // 补缺 P3-34：复制 fallback 只复制描述文字，设备信息与附件不随复制发出，toast 明说。
            UIPasteboard.general.string = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            BearyToast.show(in: view, message: "未配置邮箱，已复制反馈内容，附件不随复制发出", aboveFAB: false)
            BearyAppLog.event("feedback mail no account copy fallback")
            return
        }
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = self
        composer.setToRecipients([Self.recipient])
        composer.setSubject("\(typePrefix()) beary 反馈")
        composer.setMessageBody(submitBodyText(), isHTML: false)
        if zipReady, let url = zipURL, let zipData = try? Data(contentsOf: url) {
            composer.addAttachmentData(zipData, mimeType: "application/zip", fileName: "beary-feedback-logs.zip")
        }
        for attachment in attachments {
            composer.addAttachmentData(attachment.data, mimeType: attachment.mimeType, fileName: attachment.fileName)
        }
        present(composer, animated: BearyMotion.animated(true))
    }

    private func presentLogOnlyComposer() {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = self
        composer.setToRecipients([Self.recipient])
        composer.setSubject("[日志] beary 诊断日志")
        composer.setMessageBody("beary 诊断日志见附件。", isHTML: false)
        if let url = zipURL, let zipData = try? Data(contentsOf: url) {
            composer.addAttachmentData(zipData, mimeType: "application/zip", fileName: "beary-feedback-logs.zip")
        }
        present(composer, animated: BearyMotion.animated(true))
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
        let kind = pendingMailKind
        controller.dismiss(animated: BearyMotion.animated(true)) { [weak self] in
            guard let self = self else { return }
            // 邮件流程结束即删 tmp zip（撰写框持有的是附件数据副本，不读文件）。
            self.cleanupZip()
            let noun = kind == .logOnly ? "日志" : "反馈"
            switch result {
            case .sent:
                BearyToast.show(in: self.view, message: "\(noun)已发送", aboveFAB: false)
                BearyHaptics.publishSuccess()
                BearyAppLog.event(kind == .logOnly ? "feedback log mail sent" : "feedback mail sent")
            case .saved:
                BearyToast.show(in: self.view, message: "\(noun)已保存为草稿", aboveFAB: false)
                BearyAppLog.event(kind == .logOnly ? "feedback log mail saved" : "feedback mail saved")
            case .cancelled:
                BearyToast.show(in: self.view, message: "已取消", aboveFAB: false)
                BearyAppLog.event(kind == .logOnly ? "feedback log mail cancelled" : "feedback mail cancelled")
            case .failed:
                BearyToast.show(in: self.view, message: "\(noun)发送失败", aboveFAB: false)
                BearyHaptics.rejectionWarning()
                BearyAppLog.event(kind == .logOnly ? "feedback log mail failed" : "feedback mail failed")
            @unknown default:
                BearyToast.show(in: self.view, message: "\(noun)发送失败", aboveFAB: false)
                BearyHaptics.rejectionWarning()
            }
        }
    }

    // MARK: - 图片 / 视频选择（系统 PHPicker，最多 5 个）

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: BearyMotion.animated(true))
        guard !results.isEmpty else { return }
        let group = DispatchGroup()
        let lock = NSLock()
        var loaded: [Attachment?] = Array(repeating: nil, count: results.count)
        var failedCount = 0
        /// 审计 P2-26：超限视频计数（单视频上限 50MB，见 movie 分支先查大小再读）。
        var oversizedCount = 0
        for (index, result) in results.enumerated() {
            let provider = result.itemProvider
            group.enter()
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    defer { group.leave() }
                    guard let image = object as? UIImage,
                          let jpeg = BearyImagePrep.jpegData(image) else {
                        lock.lock()
                        failedCount += 1
                        lock.unlock()
                        return
                    }
                    lock.lock()
                    loaded[index] = Attachment(data: jpeg.data, mimeType: "image/jpeg", fileName: "feedback-image-\(index + 1).jpg")
                    lock.unlock()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                    defer { group.leave() }
                    guard let urlValue = url else {
                        lock.lock()
                        failedCount += 1
                        lock.unlock()
                        return
                    }
                    // 审计 P2-26：视频先查大小再读——超过 50MB 不读入内存（邮箱附件与
                    // 内存双重保护），计失败并在汇总提示里单独说明超限个数。
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: urlValue.path),
                       let size = attrs[.size] as? NSNumber, size.intValue > 50 * 1024 * 1024 {
                        lock.lock()
                        failedCount += 1
                        oversizedCount += 1
                        lock.unlock()
                        return
                    }
                    guard let data = try? Data(contentsOf: urlValue) else {
                        lock.lock()
                        failedCount += 1
                        lock.unlock()
                        return
                    }
                    let ext = urlValue.pathExtension.lowercased()
                    let mime: String
                    if ext == "mov" {
                        mime = "video/quicktime"
                    } else if ext == "mp4" {
                        mime = "video/mp4"
                    } else {
                        mime = "application/octet-stream"
                    }
                    let name = urlValue.lastPathComponent.isEmpty ? "feedback-video-\(index + 1).mov" : urlValue.lastPathComponent
                    lock.lock()
                    loaded[index] = Attachment(data: data, mimeType: mime, fileName: name)
                    lock.unlock()
                }
            } else {
                lock.lock()
                failedCount += 1
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.attachments = loaded.compactMap { $0 }
            self.refreshAttachUI()
            if failedCount > 0 {
                let message = oversizedCount > 0
                    ? "有 \(failedCount) 个附件未能加载，其中 \(oversizedCount) 个视频超过 50MB"
                    : "有 \(failedCount) 个附件未能加载"
                BearyToast.show(in: self.view, message: message, aboveFAB: false)
            }
        }
    }

    // MARK: - UITextViewDelegate / 键盘

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
        updateSubmitEnabled()
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        guard let value = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let bottom = max(0, value.cgRectValue.height - view.safeAreaInsets.bottom)
        scrollView.contentInset.bottom = bottom
        scrollView.verticalScrollIndicatorInsets.bottom = bottom
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }
}
