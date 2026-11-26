import UIKit

// 快照预览（2026-11-14 Li 定版，照截图改成底部弹窗两层中的预览层；
// 原「快照对比」页替换为本页：不再并排对比新旧版，只展示快照文字内容）。
// 标题「快照预览」，副行「时间 · 保存成功」；正文为快照文字（标题有则占首行，
// 与恢复写回的 title＋content 同款——服务端恢复同时写回两者）；
// 提示「请先核对快照内容。恢复前会先备份现在的文字，恢复后需手动保存。」；
// 底部橙色满宽钮「恢复到编辑器」。
// 恢复语义（与截图注文一致）：点按钮不直接写库，只把快照文字载入编辑器、
// 手动保存才落盘；保存时服务端 PUT 先把恢复前版本存为快照（既有口径），
// 故恢复前备份有兜底、不调 POST restore（它会直接写库，等于自动保存）。
// 星标能力保留：右上角星形钮，点亮橙色＝已加星标，沿用原 star 接口。

final class BearySnapshotPreviewViewController: UIViewController, BearySystemSheetSizing {
    var onStarChanged: ((Int, Bool) -> Void)?
    var onRestoreToEditor: ((BearyEntrySnapshot) -> Void)?

    private let entryId: String
    private var snapshot: BearyEntrySnapshot

    private var starRequestInFlight = false

    private let titleLabel = UILabel()
    private let starButton = UIButton(type: .system)
    private let subtitleLabel = UILabel()
    private let contentTextView = UITextView()
    private let noteLabel = UILabel()
    private let restoreButton = BearyButton.make(style: .primaryPill(.orange), title: "恢复到编辑器")
    private var textHeightConstraint: NSLayoutConstraint?

    /// 量高缓存（快照弹窗卡顿根因，见 updateTextHeight / updatePreferredContentSize）：
    /// viewDidLayoutSubviews 每轮布局都会进，高度动画期间也会反复进；
    /// 正文固定、只随宽度变，宽度没变时不再反复整篇排版、整树量高。
    private var lastTextMeasuredWidth: CGFloat = -1
    private var lastMeasuredWidth: CGFloat = -1
    private var lastMeasuredTextHeight: CGFloat = -1
    private var lastMeasuredSafeAreaBottom: CGFloat = -1
    private var lastFittingHeight: CGFloat = 0

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
        view.backgroundColor = .clear
        view.layer.cornerRadius = BearySheetChrome.topCornerRadius
        view.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        view.layer.masksToBounds = true

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "快照预览"
        titleLabel.font = BearyDynamicType.pageTitleFont()
        titleLabel.adjustsFontForContentSizeCategory = true
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
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = BearyColors.gray
        subtitleLabel.text = snapshot.displayDateString.isEmpty ? "保存成功" : "\(snapshot.displayDateString) · 保存成功"
        view.addSubview(subtitleLabel)

        contentTextView.translatesAutoresizingMaskIntoConstraints = false
        contentTextView.isEditable = false
        contentTextView.isScrollEnabled = true
        contentTextView.backgroundColor = .clear
        contentTextView.textContainerInset = .zero
        contentTextView.textContainer.lineFragmentPadding = 0
        applyContentText()
        view.addSubview(contentTextView)

        noteLabel.translatesAutoresizingMaskIntoConstraints = false
        noteLabel.font = BearyDynamicType.captionFont()
        noteLabel.adjustsFontForContentSizeCategory = true
        noteLabel.textColor = BearyColors.gray
        noteLabel.numberOfLines = 0
        noteLabel.text = NSLocalizedString("snapshot.restore_note", comment: "")
        view.addSubview(noteLabel)

        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        restoreButton.bearyAddPressFeedback()
        view.addSubview(restoreButton)

        let textHeight = contentTextView.heightAnchor.constraint(equalToConstant: Self.minTextHeight)
        textHeightConstraint = textHeight
        NSLayoutConstraint.activate([
            // 顶部留白与旧抓手区等高（抓手顶 10＋高 4＋标题间距 16）：系统抓手占顶区，标题位置不动。
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop + BearySheetChrome.grabberHeight + 16),
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

    /// 字号档变化时量高缓存失效，下一帧按新字号重算。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            lastTextMeasuredWidth = -1
            lastMeasuredWidth = -1
            // 大字号实时变化：正文富文本按当前字号重算重赋
            // （标题／副行／提示走 adjustsFontForContentSizeCategory 自动跟随）。
            applyContentText()
        }
    }

    /// 正文区按内容高撑开（上限 360pt 内部滚动），宽/字号档变化时跟帧补齐。
    /// 卡顿根因：此前每轮 viewDidLayoutSubviews 都调 contentTextView.layoutIfNeeded()
    /// 强制整篇 TextKit 排版再读 contentSize，高度动画期间每轮都排一遍；
    /// 正文在 viewDidLoad 后固定、只随宽度变，宽度没变直接跳过。
    private func updateTextHeight() {
        let width = view.bounds.width
        if width == lastTextMeasuredWidth { return }
        lastTextMeasuredWidth = width
        contentTextView.layoutIfNeeded()
        let contentHeight = contentTextView.contentSize.height
        let height = min(max(contentHeight, Self.minTextHeight), Self.maxTextHeight)
        if textHeightConstraint?.constant != height {
            textHeightConstraint?.constant = height
        }
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高；宽/字号档变化时跟帧补齐。
    /// extraBottomInset 只在进场前（未进窗口、安全区为 0）用调用方的安全区补齐。
    /// 同列表层：只有宽／正文高／底安全区变了才重算 systemLayoutSizeFitting，
    /// 其余布局轮次复用上次量到的高，不再每轮整树量一遍。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let textHeight = textHeightConstraint?.constant ?? 0
        let safeBottom = view.safeAreaInsets.bottom
        let fittingHeight: CGFloat
        if width == lastMeasuredWidth && textHeight == lastMeasuredTextHeight && safeBottom == lastMeasuredSafeAreaBottom {
            fittingHeight = lastFittingHeight
        } else {
            let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
            let size = view.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            fittingHeight = size.height
            lastMeasuredWidth = width
            lastMeasuredTextHeight = textHeight
            lastMeasuredSafeAreaBottom = safeBottom
            lastFittingHeight = fittingHeight
        }
        let height = ceil(fittingHeight) + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    /// 展示文本：标题（有则）占首行，正文随后（与原对比页同款）。
    private static func displayText(title: String?, content: String) -> String {
        guard let title = title, !title.isEmpty else { return content }
        return content.isEmpty ? title : "\(title)\n\(content)"
    }

    /// 正文富文本按当前字号生成（smallBodyFont 走 scaledFont，字号档变了须重算重赋）。
    private func applyContentText() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        paragraph.lineBreakMode = .byCharWrapping
        // 快照正文里的 [mood:] 记号走卡片同款渲染（原先纯文本直显，
        // 记号原文会露出来）；行高/断行口径与原来一致。快照不存图片，
        // [gif:] 记号按既有兜底留原文。
        contentTextView.attributedText = BearyText.inlineAttributedText(from: Self.displayText(title: snapshot.title, content: snapshot.content ?? ""), font: BearyDynamicType.smallBodyFont(), color: BearyColors.ink, paragraphStyle: paragraph, dark: traitCollection.userInterfaceStyle == .dark, gifImageKeys: nil)
    }

    private func refreshStarButton() {
        starButton.tintColor = snapshot.isStarred ? BearyColors.orange : BearyColors.gray
        starButton.accessibilityLabel = snapshot.isStarred ? "已加星标" : "加星标"
    }

    @objc private func starTapped() {
        guard let snapshotId = snapshot.id, !starRequestInFlight else { return }
        starRequestInFlight = true
        starButton.isEnabled = false
        BearyAPI.shared.toggleSnapshotStar(entryId: entryId, snapshotId: snapshotId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.starRequestInFlight = false
                self.starButton.isEnabled = true
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
        BearySystemSheet.present(sheet, from: presenter)
    }
}
