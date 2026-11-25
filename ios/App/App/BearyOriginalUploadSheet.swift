import UIKit

// ===== 选图后确认上传方式：原图 / 压缩二选一（2026-11-12 Li 定）=====
// 选完图后弹统一底部弹窗确认，按本次选的这批图生效；关闭后编辑器留
// “N 张照片待确认上传方式”条可重开；有未确认的图时点发布先弹本弹窗。
// 原图仅 Plus：非 Plus 点原图不直接选，关弹窗后由调用方弹 Plus 提示
// （文案「原图上传是 Plus 功能」，可改用压缩或了解 Plus）。
// 两项都显示大小：原图（原始文件大小）、压缩（预估大小，本地压图字节）。
// 单张原图超 5MB（服务端上限）不参与选择：已自动按压缩上传，弹窗计入总数并打标提示。
// 走系统底部 sheet（UISheetPresentationController，见 BearySystemSheet）。
// 高度上限 88% 容器高（规范 §6）。
// 部署目标 iOS 16.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

/// 上传方式标记（挂 ComposerImageItem 上，并持久化进 BearyDraftImageItem）。
/// nil＝未确认。设计上让 #1451（发布时统一上传）合入后变基好接：
/// 届时发布中心按本标记逐项取原图字节或压缩字节上传。
enum BearyUploadMode: String, Codable {
    case original
    case compressed
}

/// 弹窗展示模型：只含本次待确认批次的汇总数，不含图片本身。
struct BearyOriginalUploadSheetModel {
    /// 本次弹窗涉及的总张数（待确认项＋本批已自动压缩的超限项）；两行副文案都按此数写。
    let count: Int
    /// 原图总字节（待确认项的原图文件字节之和）。
    let originalBytes: Int
    /// 压缩后预估总字节（待确认项本地压图字节之和＋本批超限项的压缩字节）。
    let compressedBytes: Int
    /// 本批中原图超 5MB 已自动按压缩上传的张数（0 时不显示脚注）。
    let oversizeCount: Int
    /// 当前账号是否 Plus（决定原图行点按后是选中还是走 Plus 提示）。
    let isPlus: Bool
}

enum BearyOriginalUploadSheet {

    /// 从 presenter 弹出上传方式底 sheet；返回 sheet 实例（调用方弱持有）。
    /// 三个回调都在 sheet 关闭动画完成后才触发，调用方可直接再弹 Plus 页。
    @discardableResult
    static func show(from presenter: UIViewController, model: BearyOriginalUploadSheetModel,
                     onPickOriginal: @escaping () -> Void, onPickCompressed: @escaping () -> Void,
                     onShowPlus: @escaping () -> Void) -> BearyOriginalUploadSheetViewController {
        let sheet = BearyOriginalUploadSheetViewController(model: model, onPickOriginal: onPickOriginal, onPickCompressed: onPickCompressed, onShowPlus: onShowPlus)
        // 进场前先算一次内容高，首帧不拿容器一半高回退、随后不再大跳变；
        // 安全区此时未进窗口为 0，落窗后 viewDidLayoutSubviews 按真实安全区跟帧补齐。
        sheet.loadViewIfNeeded()
        sheet.containerHeight = presenter.view.bounds.height
        BearySystemSheet.present(sheet, from: presenter)
        return sheet
    }

    /// 字节数大白话：≥1MB 取一位小数 MB，≥1KB 取整数 KB，其余 B。
    static func formattedSize(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 {
            return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0)
        }
        if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024.0)
        }
        return "\(max(bytes, 0)) B"
    }
}

final class BearyOriginalUploadSheetViewController: UIViewController, BearySystemSheetSizing {

    private let model: BearyOriginalUploadSheetModel
    private let onPickOriginal: () -> Void
    private let onPickCompressed: () -> Void
    private let onShowPlus: () -> Void

    /// 关闭回调：抓手下滑/点外收起/无障碍退出等任一关闭路径都会走 viewDidDisappear，
    /// 调用方据此复位“弹窗在场”旗标；选原图/压缩的回调另在关闭动画完成后触发。
    var onDismiss: (() -> Void)?
    /// 容器高（进场前取 presenter 高，落窗后由 viewDidLayoutSubviews 按 window 高刷新）：
    /// 88% 高度上限的计算基准。
    var containerHeight: CGFloat = 800

    private let titleLabel = UILabel()
    private let originalButton = UIButton(type: .custom)
    private let compressedButton = UIButton(type: .custom)
    private let footnoteLabel = UILabel()
    private var lastLayoutWidth: CGFloat = 0
    private var lastLayoutContainerHeight: CGFloat = 0

    init(model: BearyOriginalUploadSheetModel, onPickOriginal: @escaping () -> Void, onPickCompressed: @escaping () -> Void, onShowPlus: @escaping () -> Void) {
        self.model = model
        self.onPickOriginal = onPickOriginal
        self.onPickCompressed = onPickCompressed
        self.onShowPlus = onShowPlus
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.clipsToBounds = true

        titleLabel.text = "选择上传方式"
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        configureOptionButton(originalButton, title: "原图", subtitle: "共 \(BearyOriginalUploadSheet.formattedSize(model.originalBytes)) · \(model.count) 张照片", showsCrown: !model.isPlus)
        originalButton.addTarget(self, action: #selector(originalTapped), for: .touchUpInside)
        originalButton.bearyAddPressFeedback()
        originalButton.accessibilityLabel = model.isPlus ? "原图，共 \(BearyOriginalUploadSheet.formattedSize(model.originalBytes))，\(model.count) 张照片" : "原图，仅 Plus 会员，共 \(BearyOriginalUploadSheet.formattedSize(model.originalBytes))，\(model.count) 张照片"
        view.addSubview(originalButton)

        configureOptionButton(compressedButton, title: "压缩", subtitle: "约 \(BearyOriginalUploadSheet.formattedSize(model.compressedBytes)) · \(model.count) 张照片", showsCrown: false)
        compressedButton.addTarget(self, action: #selector(compressedTapped), for: .touchUpInside)
        compressedButton.bearyAddPressFeedback()
        compressedButton.accessibilityLabel = "压缩，约 \(BearyOriginalUploadSheet.formattedSize(model.compressedBytes))，\(model.count) 张照片"
        view.addSubview(compressedButton)

        footnoteLabel.text = model.oversizeCount > 0 ? "其中 \(model.oversizeCount) 张原图超过 5MB，改用压缩上传" : nil
        footnoteLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        footnoteLabel.adjustsFontForContentSizeCategory = true
        footnoteLabel.textColor = BearyColors.gray
        footnoteLabel.numberOfLines = 0
        footnoteLabel.isHidden = model.oversizeCount <= 0
        footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footnoteLabel)

        NSLayoutConstraint.activate([
            // 顶部留白与旧抓手区等高（列表顶留白 6＋抓手高 4＋标题间距 14）：系统抓手占顶区，标题位置不动；
            // 一律不要 ×，标题右缘放回内容边 -20。
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.listTopPadding + BearySheetChrome.grabberHeight + 14),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            originalButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            originalButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            originalButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            originalButton.heightAnchor.constraint(equalToConstant: 64),
            compressedButton.topAnchor.constraint(equalTo: originalButton.bottomAnchor, constant: 12),
            compressedButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            compressedButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            compressedButton.heightAnchor.constraint(equalToConstant: 64),
            footnoteLabel.topAnchor.constraint(equalTo: compressedButton.bottomAnchor, constant: 12),
            footnoteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            footnoteLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])
    }

    /// 选项行：surface2 底＋12 圆角；左列标题 15 半粗＋副文案 12 灰；非 Plus
    /// 的原图行右端挂皇冠（与个人页皇冠同款资产），点按后走 Plus 提示。
    private func configureOptionButton(_ button: UIButton, title: String, subtitle: String, showsCrown: Bool) {
        button.backgroundColor = BearyColors.surface2
        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(titleLabel)
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(subtitleLabel)
        var constraints: [NSLayoutConstraint] = [
            titleLabel.topAnchor.constraint(equalTo: button.topAnchor, constant: BearySheetChrome.listRowVerticalPadding),
            titleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: button.bottomAnchor, constant: -BearySheetChrome.listRowVerticalPadding),
        ]
        if showsCrown, let crownImage = UIImage(named: "crown") {
            let crownView = UIImageView(image: crownImage)
            crownView.tintColor = BearyColors.orange
            crownView.contentMode = .scaleAspectFit
            crownView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(crownView)
            constraints.append(contentsOf: [
                crownView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                crownView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -16),
                crownView.widthAnchor.constraint(equalToConstant: 20),
                crownView.heightAnchor.constraint(equalToConstant: 20),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: crownView.leadingAnchor, constant: -8),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: crownView.leadingAnchor, constant: -8),
            ])
        } else {
            constraints.append(contentsOf: [
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -16),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -16),
            ])
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        let containerHeight = view.window?.bounds.height ?? self.containerHeight
        let widthChanged = abs(width - lastLayoutWidth) > 0.5
        let heightChanged = abs(containerHeight - lastLayoutContainerHeight) > 0.5
        guard widthChanged || heightChanged else { return }
        lastLayoutWidth = width
        lastLayoutContainerHeight = containerHeight
        updatePreferredContentSize()
    }

    /// 任一关闭路径（抓手下滑/点外收起/无障碍退出/选完选项）都会走这里，调用方据此复位旗标。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 系统字号档变化时行高需重算，只刷布局。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updatePreferredContentSize()
        }
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高；宽/字号档变化时跟帧补齐。
    /// 高 = 顶留白＋标题＋两行（64＋12＋64）＋脚注（有则 12＋文案高）＋底部留白。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let maxHeight = max(0, containerHeight * 0.88)
        let safeBottom = view.safeAreaInsets.bottom > 0 ? view.safeAreaInsets.bottom : extraBottomInset
        let bottomPad = safeBottom + BearySheetChrome.listBottomPadding
        let titleHeight = titleLabel.intrinsicContentSize.height
        let topHeight = BearySheetChrome.listTopPadding + BearySheetChrome.grabberHeight + 14 + titleHeight + 12
        var contentHeight: CGFloat = 64 + 12 + 64
        if !footnoteLabel.isHidden {
            let footnoteHeight = footnoteLabel.sizeThatFits(CGSize(width: max(width - 40, 0), height: CGFloat.greatestFiniteMagnitude)).height
            contentHeight += 12 + footnoteHeight
        }
        let height = min(topHeight + contentHeight + bottomPad, maxHeight)
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    /// VoiceOver 双指 scrub（无障碍退出手势）：走同一关闭路径。
    override func accessibilityPerformEscape() -> Bool {
        dismiss(animated: BearyMotion.animated(true))
        return true
    }

    @objc private func originalTapped() {
        // 回调一律在关闭动画完成后触发，调用方可直接再弹 Plus 页或起传。
        dismiss(animated: BearyMotion.animated(true)) { [weak self] in
            guard let self = self else { return }
            if self.model.isPlus {
                self.onPickOriginal()
            } else {
                self.onShowPlus()
            }
        }
    }

    @objc private func compressedTapped() {
        dismiss(animated: BearyMotion.animated(true)) { [weak self] in
            self?.onPickCompressed()
        }
    }
}
