import UIKit

// ===== 选图后确认上传方式：原图 / 压缩二选一（2026-11-12 Li 定）=====
// 选完图后弹统一底部弹窗确认，按本次选的这批图生效；关闭后编辑器留
// “N 张照片待确认上传方式”条可重开；有未确认的图时点发布先弹本弹窗。
// 原图仅 Plus：非 Plus 点原图不直接选，关弹窗后由调用方弹 Plus 提示
// （文案「原图上传是 Plus 功能」，可改用压缩或了解 Plus）。
// 两项都显示大小：原图（原始文件大小）、压缩（预估大小，本地压图字节）。
// 单张原图超 5MB（服务端上限）不进本弹窗：已自动按压缩上传并打标提示。
// 走共享底部弹窗容器 BearyBottomSheet（弹簧 0.4s 上升、背后缩 0.92、
// 遮罩 0.45、下拖超 80pt 或速度 >600pt/s 关闭、否则 0.30s/damping 0.7
// 弹回；减动效瞬时）。高度上限 88% 容器高（规范 §6）。
// 部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

/// 上传方式标记（挂 ComposerImageItem 上，并持久化进 BearyDraftImageItem）。
/// nil＝未确认。设计上让 #1451（发布时统一上传）合入后变基好接：
/// 届时发布中心按本标记逐项取原图字节或压缩字节上传。
enum BearyUploadMode: String, Codable {
    case original
    case compressed
}

/// 弹窗展示模型：只含本次待确认批次的汇总数，不含图片本身。
struct BearyOriginalUploadSheetModel {
    /// 待确认张数。
    let count: Int
    /// 原图总字节（各原图文件字节之和）。
    let originalBytes: Int
    /// 压缩后预估总字节（各图本地压图字节之和）。
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
        let delegate = BearyBottomSheetTransitioningDelegate()
        sheet.sheetDelegate = delegate
        sheet.transitioningDelegate = delegate
        sheet.modalPresentationStyle = .custom
        // 进场前先算一次内容高，首帧不拿容器一半高回退、随后不再大跳变；
        // 安全区此时未进窗口为 0，落窗后 viewDidLayoutSubviews 按真实安全区跟帧补齐。
        sheet.loadViewIfNeeded()
        let presenterWidth = presenter.view.bounds.width
        let sheetWidth: CGFloat = presenterWidth >= 821 ? min(600, presenterWidth - 32) : presenterWidth
        sheet.view.frame = CGRect(x: 0, y: 0, width: max(sheetWidth, 1), height: 800)
        sheet.view.setNeedsLayout()
        sheet.view.layoutIfNeeded()
        sheet.containerHeight = presenter.view.bounds.height
        sheet.updatePreferredContentSize(extraBottomInset: presenter.view.safeAreaInsets.bottom)
        presenter.present(sheet, animated: BearyMotion.animated(true))
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

final class BearyOriginalUploadSheetViewController: UIViewController, BearyBottomSheetVoiceOver {

    private let model: BearyOriginalUploadSheetModel
    private let onPickOriginal: () -> Void
    private let onPickCompressed: () -> Void
    private let onShowPlus: () -> Void

    /// transitioningDelegate 是弱引用，须由本页自己强持有（登录页同款做法），
    /// 否则容器在呈现中途释放、进退场动画丢 delegate。
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?
    /// 关闭回调：×/下拉/无障碍退出等任一关闭路径都会走 viewDidDisappear，
    /// 调用方据此复位“弹窗在场”旗标；选原图/压缩的回调另在关闭动画完成后触发。
    var onDismiss: (() -> Void)?
    /// 容器高（进场前取 presenter 高，落窗后由 viewDidLayoutSubviews 按 window 高刷新）：
    /// 88% 高度上限的计算基准。
    var containerHeight: CGFloat = 800

    private let grabberView = UIView()
    private let closeButton = BearyButton.closeButton()
    private let titleLabel = UILabel()
    private let originalButton = UIButton(type: .custom)
    private let compressedButton = UIButton(type: .custom)
    private let footnoteLabel = UILabel()
    private var lastLayoutWidth: CGFloat = 0
    private var lastLayoutContainerHeight: CGFloat = 0

    /// BearyBottomSheetVoiceOver：出现时首焦点落标题。
    var bottomSheetInitialAccessibilityElement: AnyObject? { titleLabel }

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
        view.backgroundColor = BearyColors.surface3
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.clipsToBounds = true

        grabberView.backgroundColor = BearyColors.line
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        grabberView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grabberView)

        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(closeButton)

        titleLabel.text = "选择上传方式"
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        configureOptionButton(originalButton, title: "原图", subtitle: "共 \(BearyOriginalUploadSheet.formattedSize(model.originalBytes)) · \(model.count) 张照片", showsCrown: !model.isPlus)
        originalButton.addTarget(self, action: #selector(originalTapped), for: .touchUpInside)
        originalButton.accessibilityLabel = model.isPlus ? "原图，共 \(BearyOriginalUploadSheet.formattedSize(model.originalBytes))，\(model.count) 张照片" : "原图，仅 Plus 会员，共 \(BearyOriginalUploadSheet.formattedSize(model.originalBytes))，\(model.count) 张照片"
        view.addSubview(originalButton)

        configureOptionButton(compressedButton, title: "压缩", subtitle: "约 \(BearyOriginalUploadSheet.formattedSize(model.compressedBytes)) · \(model.count) 张照片", showsCrown: false)
        compressedButton.addTarget(self, action: #selector(compressedTapped), for: .touchUpInside)
        compressedButton.accessibilityLabel = "压缩，约 \(BearyOriginalUploadSheet.formattedSize(model.compressedBytes))，\(model.count) 张照片"
        view.addSubview(compressedButton)

        footnoteLabel.text = model.oversizeCount > 0 ? "其中 \(model.oversizeCount) 张原图超过 5MB，改用压缩上传" : nil
        footnoteLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        footnoteLabel.textColor = BearyColors.gray
        footnoteLabel.numberOfLines = 0
        footnoteLabel.isHidden = model.oversizeCount <= 0
        footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footnoteLabel)

        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop),
            grabberView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabberView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),
            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            titleLabel.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
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
        titleLabel.textColor = BearyColors.ink
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(titleLabel)
        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(subtitleLabel)
        var constraints: [NSLayoutConstraint] = [
            titleLabel.topAnchor.constraint(equalTo: button.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: button.bottomAnchor, constant: -10),
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

    /// 任一关闭路径（×/下拉/无障碍退出/选完选项）都会走这里，调用方据此复位旗标。
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

    /// 按当前宽度算内容高，推给容器当 sheet 高；宽/字号档变化时跟帧补齐。
    /// 高 = 抓手＋标题＋两行（64＋12＋64）＋脚注（有则 12＋文案高）＋底部留白。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let maxHeight = max(0, containerHeight * 0.88)
        let safeBottom = view.safeAreaInsets.bottom > 0 ? view.safeAreaInsets.bottom : extraBottomInset
        let bottomPad = safeBottom + 16
        let titleHeight = titleLabel.intrinsicContentSize.height
        let chrome = BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 14 + titleHeight + 12
        var contentHeight: CGFloat = 64 + 12 + 64
        if !footnoteLabel.isHidden {
            let footnoteHeight = footnoteLabel.sizeThatFits(CGSize(width: max(width - 40, 0), height: CGFloat.greatestFiniteMagnitude)).height
            contentHeight += 12 + footnoteHeight
        }
        let height = min(chrome + contentHeight + bottomPad, maxHeight)
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }

    /// VoiceOver 双指 scrub（无障碍退出手势）：走同一关闭路径。
    override func accessibilityPerformEscape() -> Bool {
        closeTapped()
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
