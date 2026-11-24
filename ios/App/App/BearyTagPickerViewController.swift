import UIKit

// ===== 标签选择器底 sheet（2026-11-18 标签完整版）=====
// 写日记页功能栏 # 钮弹出：挑旧标签（我用过的，按篇数倒序）或输入新建；
// 多选，点确定回传选中列。走系统底部 sheet（UISheetPresentationController，
// 见 BearySystemSheet）。无叉叉关闭（弹窗规矩 2026-11-17：
// 关闭走抓手下滑／点外收起／取消钮）；点确定先关 sheet、关完再跑回调。
// 部署目标 iOS 16.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

enum BearyTagPicker {

    /// 标签归一化（与后端 normalizeEntryTags 同口径）：去空白、去开头的 #、
    /// 1–20 字；不合格回 nil（调用方 toast，不静默截断）。
    static func normalizeTag(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^#+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 20 else { return nil }
        return t
    }

    /// 从 presenter 弹出标签选择器（presenter 已 present 另一弹窗时跳过，不叠弹）。
    /// - Parameters:
    ///   - selected: 已选中的标签列（原序保留，新选的追加在后）。
    ///   - onConfirm: 点确定时调一次，收到选中列（可能为空，即清掉全部标签）。
    static func show(from presenter: UIViewController, selected: [String], onConfirm: @escaping ([String]) -> Void) {
        guard presenter.presentedViewController == nil else { return }
        let sheet = BearyTagPickerViewController(selected: selected, onConfirm: onConfirm)
        BearySystemSheet.present(sheet, from: presenter)
    }
}

final class BearyTagPickerViewController: UIViewController, BearySystemSheetSizing {

    private let onConfirm: ([String]) -> Void

    /// 只解析一次：点按任一按钮即定局，后到的直接丢弃，防确定/取消双跑。
    private var resolved = false

    /// 按钮组底边约束：停靠键盘时由 BearySheetKeyboardAvoidance 按键盘顶升改常量。
    private var buttonStackBottomConstraint: NSLayoutConstraint?
    /// 停靠键盘顶升（只跟停靠键盘，浮动/分屏不动，见 BearySystemSheet）。
    private var keyboardAvoidance: BearySheetKeyboardAvoidance?

    /// 服务端回的历史标签（GET /beary/api/tags，按篇数倒序）。
    private var serverTags: [BearyTag] = []
    /// 本次新建、服务端历史里还没有的标签（最新在首位），以及进来时已选、
    /// 但服务端历史里没有的标签；回包／失败都不清掉，点行可取消选中。
    private var localTags: [BearyTag] = []
    /// 面板显示列：本地标签在前、服务端历史在后，按小写 key 去重合并；
    /// 拉取失败时保持原样，选择器仍可用（可新建），不弹失败态。
    private var myTags: [BearyTag] = []
    /// 已选标签（原序保留）；去重键为小写，用于新标签与旧标签比对。
    private var selectedTags: [String]
    private var selectedKeys: Set<String>

    private let scrollView = UIScrollView()
    private let scrollContentView = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let newTagField = UITextField()
    private let addButton = BearyHit44Button(type: .system)
    /// 标签列表区容器：表与空态共用同一块高（表高 = 行数×44，至多 6 行；
    /// 空态 44），避免表与空态各绑内容底边互相顶死。
    private let tagsAreaView = UIView()
    private let tagsTableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let buttonStack = UIStackView()
    private let confirmButton = BearyButton(style: .primaryPill(.ink))
    private var tagsAreaHeightConstraint: NSLayoutConstraint?

    private static let rowHeight: CGFloat = 44
    private static let maxVisibleRows = 6

    init(selected: [String], onConfirm: @escaping ([String]) -> Void) {
        self.selectedTags = selected
        self.selectedKeys = Set(selected.map { $0.lowercased() })
        self.onConfirm = onConfirm
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
        view.layer.masksToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContentView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "标签"
        titleLabel.font = BearyDynamicType.smallActionFont()
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        scrollContentView.addSubview(titleLabel)

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.text = "点选已有标签，或输入新标签（最多 10 个，每个最多 20 个字）"
        messageLabel.font = BearyDynamicType.smallBodyFont()
        messageLabel.textColor = BearyColors.gray
        messageLabel.numberOfLines = 0
        scrollContentView.addSubview(messageLabel)

        newTagField.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 16))
        newTagField.adjustsFontForContentSizeCategory = true
        newTagField.textColor = BearyColors.ink
        newTagField.autocorrectionType = .no
        newTagField.autocapitalizationType = .none
        newTagField.returnKeyType = .done
        newTagField.placeholder = "输入新标签"
        newTagField.delegate = self
        let fieldContainer = BearyInputContainer(content: newTagField)
        fieldContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        scrollContentView.addSubview(fieldContainer)

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setTitle("添加", for: .normal)
        addButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        addButton.setTitleColor(BearyColors.ink, for: .normal)
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        addButton.bearyAddPressFeedback()
        scrollContentView.addSubview(addButton)

        tagsAreaView.translatesAutoresizingMaskIntoConstraints = false
        scrollContentView.addSubview(tagsAreaView)

        tagsTableView.translatesAutoresizingMaskIntoConstraints = false
        tagsTableView.dataSource = self
        tagsTableView.delegate = self
        tagsTableView.rowHeight = Self.rowHeight
        tagsTableView.separatorStyle = .none
        tagsTableView.backgroundColor = .clear
        tagsTableView.isScrollEnabled = false
        tagsTableView.register(UITableViewCell.self, forCellReuseIdentifier: "BearyTagPickerCell")
        tagsAreaView.addSubview(tagsTableView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.text = "还没有用过的标签，在上方输入新建"
        emptyLabel.font = BearyDynamicType.smallBodyFont()
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        tagsAreaView.addSubview(emptyLabel)

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .vertical
        buttonStack.spacing = 8
        confirmButton.translatesAutoresizingMaskIntoConstraints = false
        confirmButton.setTitle("确定", for: .normal)
        confirmButton.addTarget(self, action: #selector(confirmTapped), for: .touchUpInside)
        confirmButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(confirmButton)
        confirmButton.heightAnchor.constraint(equalToConstant: confirmButton.style.height).isActive = true
        let cancelButton = BearyButton(style: .secondaryOutline(.regular))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        cancelButton.bearyAddPressFeedback()
        buttonStack.addArrangedSubview(cancelButton)
        cancelButton.heightAnchor.constraint(equalToConstant: cancelButton.style.height).isActive = true
        view.addSubview(buttonStack)

        let tagsAreaHeight = tagsAreaView.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        tagsAreaHeightConstraint = tagsAreaHeight
        let scrollBottom = scrollView.bottomAnchor.constraint(equalTo: buttonStack.topAnchor)
        scrollBottom.priority = UILayoutPriority(rawValue: 999)
        // 按钮组底边：贴安全区底边 -10（列表 sheet 底留白）；停靠键盘时由 keyboardAvoidance 按键盘顶升改常量。
        let buttonBottom = buttonStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -BearySheetChrome.listBottomPadding)
        buttonStackBottomConstraint = buttonBottom
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollBottom,

            scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            scrollContentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            scrollContentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            scrollContentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            // 顶部留白与旧抓手区等高（列表顶留白 6＋抓手高 4＋标题间距 16）：系统抓手占顶区，标题位置不动。
            titleLabel.topAnchor.constraint(equalTo: scrollContentView.topAnchor, constant: BearySheetChrome.listTopPadding + BearySheetChrome.grabberHeight + 16),
            titleLabel.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),

            fieldContainer.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
            fieldContainer.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            fieldContainer.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -8),
            fieldContainer.bottomAnchor.constraint(equalTo: tagsAreaView.topAnchor, constant: -16),

            addButton.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),
            addButton.widthAnchor.constraint(equalToConstant: 44),

            tagsAreaView.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor, constant: 16),
            tagsAreaView.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor, constant: -16),
            tagsAreaView.bottomAnchor.constraint(equalTo: scrollContentView.bottomAnchor, constant: -16),
            tagsAreaHeight,

            tagsTableView.topAnchor.constraint(equalTo: tagsAreaView.topAnchor),
            tagsTableView.bottomAnchor.constraint(equalTo: tagsAreaView.bottomAnchor),
            tagsTableView.leadingAnchor.constraint(equalTo: tagsAreaView.leadingAnchor),
            tagsTableView.trailingAnchor.constraint(equalTo: tagsAreaView.trailingAnchor),

            emptyLabel.topAnchor.constraint(equalTo: tagsAreaView.topAnchor),
            emptyLabel.bottomAnchor.constraint(equalTo: tagsAreaView.bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: tagsAreaView.leadingAnchor),
            emptyLabel.trailingAnchor.constraint(equalTo: tagsAreaView.trailingAnchor),

            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            buttonBottom,
        ])

        refreshConfirmTitle()
        loadMyTags()

        // 停靠键盘顶升按钮组（只跟停靠键盘，浮动/分屏不动；顶升量＝键盘盖住安全区底边的部分）。
        keyboardAvoidance = BearySheetKeyboardAvoidance(view: view) { [weak self] keyboardTop in
            guard let self = self else { return }
            let lift: CGFloat
            if let top = keyboardTop {
                lift = max(0, self.view.bounds.maxY - self.view.safeAreaInsets.bottom - top)
            } else {
                lift = 0
            }
            self.buttonStackBottomConstraint?.constant = -BearySheetChrome.listBottomPadding - lift
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePreferredContentSize()
    }

    /// 按当前宽度算内容高，推给系统 sheet 当 detent 高（与 BearyInputSheet 同款公式：
    /// 滚动内容高＋按钮组高＋底边 10＋安全区底边；系统 sheet 封顶 88%）。
    func updatePreferredContentSize(extraBottomInset: CGFloat = 0) {
        let width = view.bounds.width > 0 ? view.bounds.width : 375
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        let contentHeight = scrollContentView.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let buttonsHeight = buttonStack.systemLayoutSizeFitting(target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        let height = ceil(contentHeight) + ceil(buttonsHeight) + BearySheetChrome.listBottomPadding + view.safeAreaInsets.bottom + extraBottomInset
        let preferred = CGSize(width: width, height: height)
        if preferredContentSize != preferred {
            preferredContentSize = preferred
            BearySystemSheet.refreshDetentsIfNeeded(for: self)
        }
    }

    private func loadMyTags() {
        BearyAPI.shared.fetchMyTags { [weak self] result in
            guard let self = self else { return }
            // 回包跑在 NSURLSession delegate 队列（后台线程）：直接碰 UI
            // 会在 systemLayoutSizeFitting 里触发 _AssertAutoLayoutOnAllowedThreadsOnly
            // 抛异常闪退（134 真机实证），先切回主线程再做事。
            DispatchQueue.main.async {
                switch result {
                case .success(let tags):
                    self.serverTags = tags
                    // 服务端已有的本地行不再单存（服务端行带篇数）；服务端没有的
                    // 已选标签补进本地行，面板里有行可点才能取消选中。
                    self.localTags.removeAll { local in
                        tags.contains { $0.tag.lowercased() == local.tag.lowercased() }
                    }
                    for tag in self.selectedTags {
                        let key = tag.lowercased()
                        guard !tags.contains(where: { $0.tag.lowercased() == key }),
                              !self.localTags.contains(where: { $0.tag.lowercased() == key }) else { continue }
                        self.localTags.append(BearyTag(tag: tag, count: nil))
                    }
                    self.rebuildMyTags()
                case .failure:
                    // 失败保留本地行（回包前新建的标签还在首位），只刷新显示。
                    break
                }
                self.refreshTagList()
            }
        }
    }

    /// 本地标签在前、服务端历史在后，按小写 key 去重合并成显示列。
    private func rebuildMyTags() {
        var merged = localTags
        for tag in serverTags where !merged.contains(where: { $0.tag.lowercased() == tag.tag.lowercased() }) {
            merged.append(tag)
        }
        myTags = merged
    }

    private func refreshTagList() {
        tagsTableView.reloadData()
        let count = myTags.count
        emptyLabel.isHidden = count != 0
        tagsTableView.isHidden = count == 0
        tagsTableView.isScrollEnabled = count > Self.maxVisibleRows
        tagsAreaHeightConstraint?.constant = count == 0 ? Self.rowHeight : CGFloat(min(count, Self.maxVisibleRows)) * Self.rowHeight
        updatePreferredContentSize()
    }

    private func refreshConfirmTitle() {
        confirmButton.setTitle(selectedTags.isEmpty ? "确定" : "确定（\(selectedTags.count)）", for: .normal)
    }

    private func toggleTag(_ tag: String) {
        let key = tag.lowercased()
        if selectedKeys.contains(key) {
            selectedKeys.remove(key)
            selectedTags.removeAll { $0.lowercased() == key }
        } else {
            guard selectedTags.count < 10 else {
                BearyToast.show(in: view, message: "一篇日记最多 10 个标签")
                return
            }
            selectedKeys.insert(key)
            selectedTags.append(tag)
        }
        refreshConfirmTitle()
        tagsTableView.reloadData()
    }

    @objc private func addTapped() {
        guard let raw = newTagField.text, let tag = BearyTagPicker.normalizeTag(raw) else {
            BearyToast.show(in: view, message: "标签最多 20 个字")
            return
        }
        let key = tag.lowercased()
        if !selectedKeys.contains(key) {
            guard selectedTags.count < 10 else {
                BearyToast.show(in: view, message: "一篇日记最多 10 个标签")
                return
            }
            selectedKeys.insert(key)
            selectedTags.append(tag)
        }
        // 新标签进本地列首位（即使服务端还没它，也能立即看到选中态）；
        // 服务端已有、本地没有的不重复插行。回包只刷新服务端列，不动本地列。
        if !serverTags.contains(where: { $0.tag.lowercased() == key })
            && !localTags.contains(where: { $0.tag.lowercased() == key }) {
            localTags.insert(BearyTag(tag: tag, count: nil), at: 0)
        }
        rebuildMyTags()
        newTagField.text = nil
        newTagField.resignFirstResponder()
        refreshConfirmTitle()
        refreshTagList()
    }

    @objc private func confirmTapped() {
        guard !resolved else { return }
        resolved = true
        let tags = selectedTags
        let handler = onConfirm
        dismiss(animated: BearyMotion.animated(true)) {
            handler(tags)
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true))
    }
}

extension BearyTagPickerViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        myTags.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyTagPickerCell", for: indexPath)
        let item = myTags[indexPath.row]
        cell.textLabel?.text = "#" + item.tag
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16)
        cell.textLabel?.textColor = BearyColors.ink
        if let count = item.count {
            cell.detailTextLabel?.text = "\(count) 篇"
            cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 13)
            cell.detailTextLabel?.textColor = BearyColors.gray
        } else {
            cell.detailTextLabel?.text = nil
        }
        cell.backgroundColor = .clear
        cell.selectionStyle = .none
        let isSelected = selectedKeys.contains(item.tag.lowercased())
        if isSelected {
            let check = UIImageView(image: BearyIconImages.image(named: "icon_check", pointSize: 16))
            check.tintColor = BearyColors.ink
            cell.accessoryView = check
        } else {
            cell.accessoryView = nil
        }
        cell.accessibilityLabel = "#" + item.tag + (isSelected ? "，已选" : "，未选")
        return cell
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        guard indexPath.row < myTags.count else { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        toggleTag(myTags[indexPath.row].tag)
    }
}

extension BearyTagPickerViewController: UITextFieldDelegate {

    /// 键盘 Return（.done）走添加同款路径。
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        addTapped()
        return false
    }
}
