import UIKit

// 快照列表（2026-11-11 产品冲突清单第 4 条定版）：详情页 ••• 菜单「快照」进入，
// 仅作者本人可见；只列最近 7 天内产生的文字版本，星标版长期保留；点行进对比页。

final class BearySnapshotListViewController: UIViewController {
    var onRestored: (() -> Void)?

    private let entry: Entry
    private var snapshots: [BearyEntrySnapshot] = []
    private var loadFailed = false

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.secondaryFont()
        label.textColor = BearyColors.gray
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    init(entry: Entry) {
        self.entry = entry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        title = "快照"
        if let backImage = BearyIconImages.image(named: "icon_back", pointSize: 24) {
            navigationItem.leftBarButtonItem = UIBarButtonItem(image: backImage, style: .plain, target: self, action: #selector(closeTapped))
        } else {
            navigationItem.leftBarButtonItem = UIBarButtonItem(title: "返回", style: .plain, target: self, action: #selector(closeTapped))
        }
        navigationItem.leftBarButtonItem?.tintColor = BearyColors.ink

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorColor = BearyColors.line
        tableView.dataSource = self
        tableView.delegate = self
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        loadSnapshots()
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
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

    private func previewText(for snapshot: BearyEntrySnapshot) -> String {
        let text = [snapshot.title, snapshot.content].compactMap { $0 }.joined(separator: "\n")
        let firstLine = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return firstLine ?? ""
    }
}

// MARK: - UITableViewDataSource / UITableViewDelegate

extension BearySnapshotListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        snapshots.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearySnapshotCell")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "BearySnapshotCell")
        let snapshot = snapshots[indexPath.row]
        let dateText = snapshot.createdAt.map { BearyDiaryCardCell.feedTimeString(ms: $0) } ?? ""
        cell.textLabel?.text = snapshot.isStarred ? "\(dateText)  ★" : dateText
        cell.textLabel?.font = BearyDynamicType.smallSemiboldFont()
        cell.textLabel?.textColor = BearyColors.ink
        cell.detailTextLabel?.text = previewText(for: snapshot)
        cell.detailTextLabel?.font = BearyDynamicType.smallBodyFont()
        cell.detailTextLabel?.textColor = BearyColors.gray
        cell.detailTextLabel?.numberOfLines = 2
        cell.backgroundColor = BearyColors.bg
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: BearyMotion.animated(true))
        let snapshot = snapshots[indexPath.row]
        let compareVC = BearySnapshotCompareViewController(
            entryId: entry.id ?? "",
            snapshot: snapshot,
            currentContent: entry.content ?? "",
            currentTitle: entry.title
        )
        compareVC.onStarChanged = { [weak self] snapshotId, starred in
            guard let self = self else { return }
            if let row = self.snapshots.firstIndex(where: { $0.id == snapshotId }) {
                self.snapshots[row].starred = starred ? 1 : 0
                self.tableView.reloadRows(at: [IndexPath(row: row, section: 0)], with: .none)
            }
        }
        compareVC.onRestored = { [weak self] in
            self?.onRestored?()
        }
        navigationController?.pushViewController(compareVC, animated: BearyMotion.animated(true))
    }
}
