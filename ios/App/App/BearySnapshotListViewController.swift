import UIKit

// 快照列表（2026-11-14 Li 定版，照截图改成底部弹窗两层中的列表层）：
// 详情页 ••• 菜单「快照」进入，仅作者本人可见；只列最近 7 天内产生的文字版本，
// 星标版长期保留。排序沿用服务端口径：created_at 倒序，星标不置顶（只豁免 7 天清理）。
// 行：首行绝对时间（yyyy-MM-dd HH:mm:ss，等宽数字）＋星标 ★，次行固定
// 「纯文本 · 保存成功」（快照只存文字、存下来即保存成功，服务端无逐条状态字段）；
// 点行进预览层。右上「清空快照」删全部（含已加星标），先弹确认、不可撤销。
// 字号照截图实测：标题 pageTitleFont 17 粗体、说明与副行 captionFont 12、行时间 17 半粗。

final class BearySnapshotListViewController: UIViewController {
    /// 恢复到编辑器：预览层点「恢复到编辑器」后经本层透传给详情页
    /// （快照文字载入编辑器，手动保存；不调 POST restore、不直接写库）。
    var onRestoreSnapshotToEditor: ((BearyEntrySnapshot) -> Void)?

    private let entry: Entry
    private var snapshots: [BearyEntrySnapshot] = []
    private var loadFailed = false

    /// transitioningDelegate 是弱引用，须由本页自己强持有（登录页/公告同款做法）。
    var sheetDelegate: BearyBottomSheetTransitioningDelegate?

    private let grabberView = UIView()
    private let titleLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let descriptionLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private var tableHeightConstraint: NSLayoutConstraint?

    /// 行高 64：时间 17＋副行 12＋行距＋上下留白；表最多露 6 行，超出滚动。
    private static let rowHeight: CGFloat = 64
    private static let maxTableHeight: CGFloat = 384

    init(entry: Entry) {
        self.entry = entry
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
        titleLabel.text = "本地快照"
        titleLabel.font = BearyDynamicType.pageTitleFont()
        titleLabel.textColor = BearyColors.ink
        view.addSubview(titleLabel)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setImage(BearyIconImages.image(named: "icon_trash", pointSize: 16), for: .normal)
        clearButton.setTitle("清空快照", for: .normal)
        clearButton.titleLabel?.font = BearyDynamicType.buttonFont()
        clearButton.setTitleColor(BearyColors.orange, for: .normal)
        clearButton.tintColor = BearyColors.orange
        clearButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clearButton.bearyAddPressFeedback()
        view.addSubview(clearButton)

        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = BearyDynamicType.captionFont()
        descriptionLabel.textColor = BearyColors.gray
        descriptionLabel.numberOfLines = 0
        descriptionLabel.text = "日记内容丢失或异常时，可尝试通过快照找回。仅保留最近七天的文字版本，保存在本机，不含图片和附件。"
        view.addSubview(descriptionLabel)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.surface3
        tableView.separatorColor = BearyColors.line
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        tableView.rowHeight = Self.rowHeight
        tableView.estimatedRowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(BearySnapshotRowCell.self, forCellReuseIdentifier: "BearySnapshotRowCell")
        view.addSubview(tableView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = BearyDynamicType.secondaryFont()
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        view.addSubview(emptyLabel)

        let tableHeight = tableView.heightAnchor.constraint(equalToConstant: 0)
        tableHeightConstraint = tableHeight
        NSLayoutConstraint.activate([
            grabberView.topAnchor.constraint(equalTo: view.topAnchor, constant: BearySheetChrome.grabberTop),
            grabberView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            grabberView.widthAnchor.constraint(equalToConstant: BearySheetChrome.grabberWidth),
            grabberView.heightAnchor.constraint(equalToConstant: BearySheetChrome.grabberHeight),

            titleLabel.topAnchor.constraint(equalTo: grabberView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            clearButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            descriptionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            descriptionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableView.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableHeight,
            tableView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        loadSnapshots()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
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

    private func loadSnapshots() {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        BearyAPI.shared.fetchSnapshots(entryId: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let snapshots):
                    self.loadFailed = false
                    self.snapshots = snapshots
                case .failure:
                    self.loadFailed = true
                    self.snapshots = []
                    BearyToast.show(in: self.view, message: "快照加载失败，请重试")
                }
                self.refreshEmptyState()
                self.updateTableHeight()
                self.tableView.reloadData()
            }
        }
    }

    private func refreshEmptyState() {
        if loadFailed {
            emptyLabel.text = "加载失败，请关闭后重试"
            emptyLabel.isHidden = false
        } else if snapshots.isEmpty {
            emptyLabel.text = "暂无快照"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func updateTableHeight() {
        // 空态留 76pt 给居中的空提示；有行时按行数算、最多露 6 行。
        let height = snapshots.isEmpty ? 76 : min(CGFloat(snapshots.count) * Self.rowHeight, Self.maxTableHeight)
        if tableHeightConstraint?.constant != height {
            tableHeightConstraint?.constant = height
        }
    }

    @objc private func clearTapped() {
        BearyConfirmSheet.show(from: self, title: "清空快照？", message: "将删除这篇日记的全部快照，包括已加星标的版本，此操作不可撤销。", actions: [
            BearyConfirmSheet.Action(title: "清空", style: .destructive, handler: { [weak self] in
                self?.clearSnapshots()
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel, handler: {}),
        ])
    }

    private func clearSnapshots() {
        guard let entryId = entry.id, !entryId.isEmpty else { return }
        BearyAPI.shared.clearSnapshots(entryId: entryId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    self.loadFailed = false
                    self.snapshots = []
                    self.refreshEmptyState()
                    self.updateTableHeight()
                    self.tableView.reloadData()
                    BearyToast.show(in: self.view, message: "快照已清空")
                case .failure:
                    BearyToast.show(in: self.view, message: "操作失败，请重试")
                }
            }
        }
    }
}

// MARK: - 弹出（公告底 sheet 同款容器口径）

extension BearySnapshotListViewController {
    static func show(from presenter: UIViewController, entry: Entry, onRestoreSnapshotToEditor: ((BearyEntrySnapshot) -> Void)?) {
        let sheet = BearySnapshotListViewController(entry: entry)
        sheet.onRestoreSnapshotToEditor = onRestoreSnapshotToEditor
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

// MARK: - 行

private final class BearySnapshotRowCell: UITableViewCell {
    private let timeLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.surface3
        accessoryType = .disclosureIndicator
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.font = BearyDynamicType.tabularDigitsFont(ofSize: 17, weight: .semibold)
        timeLabel.textColor = BearyColors.ink
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = BearyDynamicType.captionFont()
        subtitleLabel.textColor = BearyColors.gray
        contentView.addSubview(timeLabel)
        contentView.addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            timeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            timeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
            subtitleLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 3),
            subtitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with snapshot: BearyEntrySnapshot) {
        timeLabel.text = snapshot.isStarred ? "\(snapshot.displayDateString)  ★" : snapshot.displayDateString
        subtitleLabel.text = "纯文本 · 保存成功"
    }
}

// MARK: - UITableViewDataSource / UITableViewDelegate

extension BearySnapshotListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        snapshots.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "BearySnapshotRowCell", for: indexPath) as? BearySnapshotRowCell else {
            return UITableViewCell()
        }
        cell.configure(with: snapshots[indexPath.row])
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: BearyMotion.animated(true))
        let snapshot = snapshots[indexPath.row]
        BearySnapshotPreviewViewController.show(
            from: self,
            entryId: entry.id ?? "",
            snapshot: snapshot,
            onStarChanged: { [weak self] snapshotId, starred in
                guard let self = self else { return }
                if let row = self.snapshots.firstIndex(where: { $0.id == snapshotId }) {
                    self.snapshots[row].starred = starred ? 1 : 0
                    self.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
                }
            },
            onRestoreToEditor: { [weak self] snapshot in
                self?.onRestoreSnapshotToEditor?(snapshot)
            }
        )
    }
}
