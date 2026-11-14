import UIKit

// 快照预览（2026-11-14 Li 定版，照截图改成底部弹窗两层中的预览层；
// 原「快照对比」页替换为本页：不再并排对比新旧版，只展示快照文字内容）。
// 标题「快照预览」，副行「时间 · 保存成功」；正文为快照文字（标题有则占首行，
// 与恢复写回的 title＋content 同款——服务端恢复同时写回两者）；
// 提示「请先核对快照内容。恢复前会备份当前非空文字，恢复后需手动保存。」；
// 底部橙色满宽钮「恢复到编辑器」。
// 恢复语义（与截图注文一致）：点按钮不直接写库，只把快照文字载入编辑器、
// 手动保存才落盘；保存时服务端 PUT 先把恢复前版本存为快照（既有口径），
// 故恢复前备份有兜底、不调 POST restore（它会直接写库，等于自动保存）。
// 星标能力保留：右上角星形钮，点亮橙色＝已加星标，沿用原 star 接口。

final class BearySnapshotPreviewViewController: UIViewController {
    var onStarChanged: ((Int, Bool) -> Void)?
    var onRestoreToEditor: ((BearyEntrySnapshot) -> Void)?

    private let entryId: String
    private var snapshot: BearyEntrySnapshot

    /// transitioningDelegate 是弱引用，须由本页自己强持有（登录页/公告同款做法）。
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?

    private let grabberView = UIView()
    private let titleLabel = UILabel()
    private let starButton = UIButton(type: .system)
    private let subtitleLabel = UILabel()
    private let contentTextView = UITextView()
    private let noteLabel = UILabel()
    private let restoreButton = BearyButton.make(style: .primaryPill(.orange), title: "恢复到编辑器")
    private var textHeightConstraint: NSLayoutConstraint?

    /// 正文区最高 360pt，超出内部滚动；最少 80pt，空内容也不塌。
    private static let maxTextHeight: CGFloat = 360
    private static let minTextHeight: CGFloat = 80

    init(entryId: String, snapshot: BearyEntrySnapshot) {
        self.entryId = entryId
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.surface3
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        grabberView.translatesAutoresizingMaskIntoConstraints = false
        grabberView.backgroundColor = BearyColors.gray
        grabberView.layer.cornerRadius = BearySheetChrome.grabberCornerRadius
        view.addSubview(grabberView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "快照预览"
        titleLabel.font = BearyDynamicType.pageTitleFont()
        titleLabel.textColor = BearyColors.ink
        view.addSubview(titleLabel)

        starButton.translatesAutoresizingMaskIntoConstraints = false
        starButton.setImage(BearyIconImages.image(named: "icon_star", pointSize: 20), for: .normal)
        starButton.addTarget(self, action: #selector(starTapped), for: .touchUpInside)
        starButton.bearyAddPressFeedback()
        refreshStarButton()
        view.addSubview(starButton)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = BearyDynamicType.captionFont()
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.text = snapshot.displayDateString.isEmpty ? "保存成功" : "\(snapshot.displayDateString) · 保存成功"
        view.addSubview(subtitleLabel)

        contentTextView.translatesAutoresizingMaskIntoConstraints = false
        contentTextView.isEditable = false
        contentTextView.isScrollEnabled = true
        contentTextView.backgroundColor = .clear
        contentTextView.textContainerInset = .zero
        contentTextView.textContainer.lineFragmentPadding = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        paragraph.lineBreakMode = .byCharWrapping
        contentTextView.attributedText = NSAttributedString(
            string: Self.displayText(title: snapshot.title, content: snapshot.content ?? ""),
            attributes: [.font: BearyDynamicType.smallBodyFont(), .foregroundColor: BearyColors.ink, .paragraphStyle: paragraph])
        view.addSubview(contentTextView)

        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.font = BearyDynamicType.captionFont()
        noteLabel.textColor = BearyColors.gray
        noteLabel.numberOfLines = 0
        noteLabel.text = "请先核对快照内容。恢复前会备份当前非空文字，恢复后需手动保存。"
        view.addSubview(noteLabel)

        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        restoreButton.bearyAddPressFeedback()
        view.addSubview(restoreButton)

        let textHeight = contentTextView.heightAnchor.constraint(equalToConstant: Self.minTextHeight)
        textHeightConstraint = textHeight
        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop),
            grabberView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabberView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),

            titleLabel.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            starButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            starButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            starButton.widthAnchor.constraint(equalToConstant: 44),
            starButton.heightAnchor.constraint(equalToConstant: 44),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            contentTextView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 16),
            contentTextView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentTextView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textHeight,

            noteLabel.topAnchor.constraint(equalTo: contentTextView.bottomAnchor, constant: 16),
            noteLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            noteLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            restoreButton.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 16),
            restoreButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            restoreButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            restoreButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.orange).height),
            restoreButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTextHeight()
        updatePreferredContentSize()
    }

    /// 正文区按内容高撑开（上限 360pt 内部滚动），宽/字号档变化时跟帧补齐。
    private func updateTextHeight() {
        contentTextView.layoutIfNeeded()
        let contentHeight = contentTextView.contentSize.height
        let height = min(max(contentHeight, Self.minTextHeight), Self.maxTextHeight)
        if textHeightConstraint?.constant != height {
            textHeightConstraint?.constant = height
        }
    }

    /// 按当前宽度算内容高，推给容器当 sheet 高；宽/字号档变化时跟帧补齐。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = ceil(size.height) + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
        }
    }

    /// 展示文本：标题（有则）占首行，正文随后（与原对比页同款）。
    private static func displayText(title: String?, content: String) -> String {
        guard let title = title, !title.isEmpty else { return content }
        return content.isEmpty ? title : "\(title)\n\(content)"
    }

    private func refreshStarButton() {
        starButton.tintColor = snapshot.isStarred ? BearyColors.orange : BearyColors.gray
        starButton.accessibilityLabel = snapshot.isStarred ? "已加星标" : "加星标"
    }

    @objc private func starTapped() {
        guard let snapshotId = snapshot.id else { return }
        BearyAPI.shared.toggleSnapshotStar(entryId: entryId, snapshotId: snapshotId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    let starred = (resp.starred ?? 0) == 1
                    self.snapshot.starred = starred ? 1 : 0
                    self.refreshStarButton()
                    self.onStarChanged?(snapshotId, starred)
                case .failure:
                    BearyToast.show(in: self.view, message: "操作失败，请重试")
                }
            }
        }
    }

    @objc private func restoreTapped() {
        // 不直接写库：只把快照文字载入编辑器，手动保存才落盘（见文件头注释）。
        onRestoreToEditor?(snapshot)
    }
}

// MARK: - 弹出（公告底 sheet 同款容器口径）

extension BearySnapshotPreviewViewController {
    static func show(from presenter: UIViewController, entryId: String, snapshot: BearyEntrySnapshot, onStarChanged: ((Int, Bool) -> Void)?, onRestoreToEditor: ((BearyEntrySnapshot) -> Void)?) {
        let sheet = BearySnapshotPreviewViewController(entryId: entryId, snapshot: snapshot)
        sheet.onStarChanged = onStarChanged
        sheet.onRestoreToEditor = onRestoreToEditor
        let delegate = BearyBottomSheetTransitioningDelegate()
        sheet.sheetDelegate = delegate
        sheet.transitioningDelegate = delegate
        sheet.modalPresentationStyle = .custom
        sheet.loadViewIfNeeded()
        let presenterWidth = presenter.view.bounds.width
        let sheetWidth: CGFloat = presenterWidth >= 821 ? min(600, presenterWidth - 32) : presenterWidth
        sheet.view.frame = CGRect(x: 0, y: 0, width: max(sheetWidth, 1), height: 800)
        sheet.view.setNeedsLayout()
        sheet.view.layoutIfNeeded()
        sheet.updatePreferredContentSize(extraBottomInset: presenter.view.safeAreaInsets.bottom)
        presenter.present(sheet, animated: BearyMotion.animated(true))
    }
}
