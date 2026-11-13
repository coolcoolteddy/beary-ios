import UIKit

// 快照对比（2026-11-11 产品冲突清单第 4 条定版）：新旧两版文字对比，改动行高亮；
// 一键恢复只恢复文字，界面明写「只恢复文字」；星标只由用户手动加。

final class BearySnapshotCompareViewController: UIViewController {
    var onStarChanged: ((Int, Bool) -> Void)?
    var onRestored: (() -> Void)?

    private let entryId: String
    private var snapshot: BearyEntrySnapshot
    private let currentContent: String
    private let currentTitle: String?

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let noteLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.secondaryFont()
        label.textColor = BearyColors.gray
        label.numberOfLines = 0
        label.text = "只恢复文字，不动现在的照片。"
        return label
    }()
    private let currentTextView = UITextView()
    private let snapshotTextView = UITextView()
    private let restoreButton = UIButton(type: .system)

    init(entryId: String, snapshot: BearyEntrySnapshot, currentContent: String, currentTitle: String?) {
        self.entryId = entryId
        self.snapshot = snapshot
        self.currentContent = currentContent
        self.currentTitle = currentTitle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        title = "快照对比"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: snapshot.isStarred ? "★ 已加星" : "☆ 加星标",
            style: .plain, target: self, action: #selector(starTapped))
        navigationItem.rightBarButtonItem?.tintColor = BearyColors.ink

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 16
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -32),
        ])

        contentStack.addArrangedSubview(noteLabel)
        contentStack.addArrangedSubview(sectionLabel(text: "当前版本"))
        contentStack.addArrangedSubview(currentTextView)
        let snapshotDate = snapshot.createdAt.map { BearyDiaryCardCell.feedTimeString(ms: $0) } ?? ""
        contentStack.addArrangedSubview(sectionLabel(text: snapshotDate.isEmpty ? "快照版本" : "快照版本 · \(snapshotDate)"))
        contentStack.addArrangedSubview(snapshotTextView)

        for textView in [currentTextView, snapshotTextView] {
            textView.translatesAutoresizingMaskIntoConstraints = false
            textView.isEditable = false
            textView.isScrollEnabled = false
            textView.backgroundColor = BearyColors.surface1
            textView.layer.cornerRadius = BearyCorners.single
            textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        }
        let (oldAttributed, newAttributed) = BearySnapshotDiff.highlighted(
            old: BearySnapshotDiff.displayText(title: snapshot.title, content: snapshot.content ?? ""),
            new: BearySnapshotDiff.displayText(title: currentTitle, content: currentContent))
        snapshotTextView.attributedText = oldAttributed
        currentTextView.attributedText = newAttributed

        restoreButton.translatesAutoresizingMaskIntoConstraints = false
        restoreButton.setTitle("恢复到这个版本", for: .normal)
        restoreButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        restoreButton.setTitleColor(BearyColors.bg, for: .normal)
        restoreButton.backgroundColor = BearyColors.ink
        restoreButton.layer.cornerRadius = BearyCorners.single
        restoreButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        restoreButton.bearyAddPressFeedback()
        contentStack.addArrangedSubview(restoreButton)
    }

    private func sectionLabel(text: String) -> UILabel {
        let label = UILabel()
        label.font = BearyDynamicType.smallSemiboldFont()
        label.textColor = BearyColors.ink
        label.text = text
        return label
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
                    self.navigationItem.rightBarButtonItem?.title = starred ? "★ 已加星" : "☆ 加星标"
                    self.onStarChanged?(snapshotId, starred)
                case .failure:
                    BearyToast.show(in: self.view, message: "操作失败，请重试")
                }
            }
        }
    }

    @objc private func restoreTapped() {
        guard let snapshotId = snapshot.id else { return }
        BearyConfirmSheet.show(from: self, title: "恢复到这个版本？", message: "只恢复文字，不动现在的照片。恢复前会先自动存一遍当前版本。", actions: [
            BearyConfirmSheet.Action(title: "恢复", style: .default, handler: { [weak self] in
                guard let self = self else { return }
                BearyAPI.shared.restoreSnapshot(entryId: self.entryId, snapshotId: snapshotId) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        switch result {
                        case .success:
                            // 成功提示由详情页在关页后弹（本页随关页消失，toast 会一并消失）。
                            self.onRestored?()
                        case .failure:
                            BearyToast.show(in: self.view, message: "恢复失败，请重试")
                        }
                    }
                }
            }),
            BearyConfirmSheet.Action(title: "取消", style: .cancel, handler: {}),
        ])
    }
}

// MARK: - 行级 diff（改动行高亮）

enum BearySnapshotDiff {
    /// 展示文本：标题（有则）占首行，正文随后；标题变化同样按行参与 diff。
    static func displayText(title: String?, content: String) -> String {
        guard let title = title, !title.isEmpty else { return content }
        return content.isEmpty ? title : "\(title)\n\(content)"
    }

    /// 行级 LCS diff：旧版独有的行红底、新版独有的行绿底，其余行无底色。
    /// 先裁掉相同的首尾行再建表（首尾行永不标色，结果与全表一致），
    /// 裁后矩阵仍超上限时退化为集合差分，不建表。
    static func highlighted(old: String, new: String) -> (old: NSAttributedString, new: NSAttributedString) {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let (oldRemoved, newAdded) = diffLineIndices(old: oldLines, new: newLines)
        return (attributed(lines: oldLines, highlighted: oldRemoved, color: BearyColors.red),
                attributed(lines: newLines, highlighted: newAdded, color: BearyColors.green))
    }

    /// 行下标 diff：返回（旧版独有行下标，新版独有行下标）。
    /// 注：重复行横跨裁剪边界时，全表回溯与裁后回溯可能标在内容相同的
    /// 不同行上（同为合法 LCS diff，高亮的文字内容一致），属预期内差异。
    private static func diffLineIndices(old: [String], new: [String]) -> (removed: Set<Int>, added: Set<Int>) {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
            suffix += 1
        }
        let oldMid = Array(old[prefix..<(old.count - suffix)])
        let newMid = Array(new[prefix..<(new.count - suffix)])
        guard !oldMid.isEmpty || !newMid.isEmpty else { return ([], []) }
        // 大输入上限：矩阵 (n+1)×(m+1) 个 Int，超 25 万格（约 2MB）时
        // 不建表，退化为集合差分（只认“对方没有的行”，O(n+m)）。
        if (oldMid.count + 1) * (newMid.count + 1) > 250_000 {
            let newSet = Set(newMid)
            let oldSet = Set(oldMid)
            var removed = Set<Int>()
            var added = Set<Int>()
            for (offset, line) in oldMid.enumerated() where !newSet.contains(line) {
                removed.insert(prefix + offset)
            }
            for (offset, line) in newMid.enumerated() where !oldSet.contains(line) {
                added.insert(prefix + offset)
            }
            return (removed, added)
        }
        let lcs = lcsTable(oldMid, newMid)
        var removed = Set<Int>()
        var added = Set<Int>()
        var i = oldMid.count, j = newMid.count
        while i > 0 || j > 0 {
            if i > 0, j > 0, oldMid[i - 1] == newMid[j - 1] {
                i -= 1; j -= 1
            } else if j > 0, (i == 0 || lcs[i][j - 1] >= lcs[i - 1][j]) {
                added.insert(prefix + j - 1); j -= 1
            } else if i > 0 {
                removed.insert(prefix + i - 1); i -= 1
            }
        }
        return (removed, added)
    }

    private static func lcsTable(_ a: [String], _ b: [String]) -> [[Int]] {
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        guard !a.isEmpty, !b.isEmpty else { return table }
        for i in 1...a.count {
            for j in 1...b.count {
                table[i][j] = a[i - 1] == b[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return table
    }

    private static func attributed(lines: [String], highlighted: Set<Int>, color: UIColor) -> NSAttributedString {
        let font = BearyDynamicType.diaryBodyFont()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        paragraph.lineBreakMode = .byCharWrapping
        let result = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: BearyColors.ink,
                .paragraphStyle: paragraph,
                .backgroundColor: highlighted.contains(index) ? BearyColors.alpha(color, 0.12) : UIColor.clear,
            ]
            result.append(NSAttributedString(string: line, attributes: attrs))
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: attrs))
            }
        }
        return result
    }
}
