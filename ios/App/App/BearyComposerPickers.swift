import UIKit

// ===== 编辑器写给选人（网页对齐批）=====
// 写给选人：调 GET /beary/api/search?q=，只取 users 组（display_name/handle 匹配，≤8 条，
// 与网页搜索同口径），结果过滤掉本人；点行即回传 SearchUser，调用方负责写给 chip 与通知开关。
// 呈现：底 sheet（UISheetPresentationController，medium/large 两档 + 抓手，文件内自包含，
// 不碰 SceneDelegate）；搜索框为图标 + “搜索昵称或 @用户名”；init/loading/none/fail 四态齐全；
// 加载态为搜索框内转圈（图标位换 spinner，不再居中大转圈）。
// 引用选择不再是独立导航页：已改为编辑器内嵌展开面板（见 BearyComposerViewController），
// 本文件旧的 BearyQuotePickerViewController 已删除。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 写给选人（底 sheet）

final class BearyRecipientPickerViewController: UIViewController, UITextFieldDelegate {

    /// 点行回传（调用方写 selectedRecipient；本页随后自行 dismiss）。
    var onPick: ((SearchUser) -> Void)?

    private let headerIconWrap = UIView()
    private let headerIcon = UIImageView()
    private let headerTitle = UILabel()
    private let closeButton = UIButton(type: .system)
    private let searchBox = UIView()
    private let searchIcon = UIImageView()
    private let searchSpinner = UIActivityIndicatorView(style: .medium)
    private let searchField = UITextField()
    private let listContainer = UIView()
    private let listScrollView = UIScrollView()
    private let rowsStack = UIStackView()
    private let stateView = UIView()
    private let stateCircle = UIView()
    private let stateIcon = UIImageView()
    private let stateSpinner = UIActivityIndicatorView(style: .medium)
    private let stateTitle = UILabel()
    private let stateSubtitle = UILabel()
    private let stateRetryButton = UIButton(type: .system)
    private var users: [SearchUser] = []
    private var searchTimer: Timer?
    private var searchSeq = 0
    private var lastQuery = ""

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 20
        }
        buildViews()
        showState(kind: "init", query: "")
        searchField.becomeFirstResponder()
    }

    deinit {
        searchTimer?.invalidate()
    }

    private func buildViews() {
        headerIconWrap.backgroundColor = BearyColors.orange.withAlphaComponent(0.20)
        headerIconWrap.layer.cornerRadius = 20
        headerIconWrap.layer.masksToBounds = true
        headerIcon.image = UIImage(systemName: "at")
        headerIcon.tintColor = BearyColors.orange
        headerIcon.contentMode = .scaleAspectFit
        headerTitle.text = "写给谁"
        headerTitle.font = UIFont.boldSystemFont(ofSize: 16)
        headerTitle.textColor = BearyColors.ink
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.backgroundColor = BearyColors.faint
        closeButton.layer.cornerRadius = 16
        closeButton.layer.masksToBounds = true
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        searchBox.backgroundColor = BearyColors.faint
        searchBox.layer.cornerRadius = 24
        searchBox.layer.masksToBounds = true
        searchBox.layer.borderWidth = 1
        searchBox.layer.borderColor = BearyColors.line.cgColor
        searchIcon.image = UIImage(systemName: "magnifyingglass")
        searchIcon.tintColor = BearyColors.gray
        searchIcon.contentMode = .scaleAspectFit
        searchSpinner.color = BearyColors.gray
        searchSpinner.hidesWhenStopped = true
        searchField.placeholder = "搜索昵称或 @用户名"
        searchField.font = UIFont.systemFont(ofSize: 16)
        searchField.textColor = BearyColors.ink
        searchField.delegate = self
        searchField.returnKeyType = .search
        searchField.addTarget(self, action: #selector(searchFieldChanged), for: .editingChanged)
        rowsStack.axis = .vertical
        rowsStack.spacing = 0
        stateCircle.backgroundColor = BearyColors.orange.withAlphaComponent(0.18)
        stateCircle.layer.cornerRadius = 27
        stateCircle.layer.masksToBounds = true
        stateIcon.tintColor = BearyColors.orange
        stateIcon.contentMode = .scaleAspectFit
        stateSpinner.color = BearyColors.orange
        stateSpinner.hidesWhenStopped = true
        stateTitle.font = UIFont.boldSystemFont(ofSize: 15)
        stateTitle.textColor = BearyColors.ink
        stateTitle.textAlignment = .center
        stateSubtitle.font = UIFont.systemFont(ofSize: 12.5)
        stateSubtitle.textColor = BearyColors.gray
        stateSubtitle.textAlignment = .center
        stateSubtitle.numberOfLines = 0
        stateRetryButton.setTitle("重试", for: .normal)
        stateRetryButton.setTitleColor(BearyColors.blue, for: .normal)
        stateRetryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        stateRetryButton.isHidden = true
        stateRetryButton.addTarget(self, action: #selector(didTapStateRetry), for: .touchUpInside)
        for v in [headerIconWrap, headerIcon, headerTitle, closeButton, searchBox, searchIcon, searchSpinner, searchField, listContainer, listScrollView, rowsStack, stateView, stateCircle, stateIcon, stateSpinner, stateTitle, stateSubtitle, stateRetryButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        view.addSubview(headerIconWrap)
        headerIconWrap.addSubview(headerIcon)
        view.addSubview(headerTitle)
        view.addSubview(closeButton)
        view.addSubview(searchBox)
        searchBox.addSubview(searchIcon)
        searchBox.addSubview(searchSpinner)
        searchBox.addSubview(searchField)
        view.addSubview(listContainer)
        listContainer.addSubview(listScrollView)
        listScrollView.addSubview(rowsStack)
        listContainer.addSubview(stateView)
        stateView.addSubview(stateCircle)
        stateCircle.addSubview(stateIcon)
        stateCircle.addSubview(stateSpinner)
        stateView.addSubview(stateTitle)
        stateView.addSubview(stateSubtitle)
        stateView.addSubview(stateRetryButton)
        NSLayoutConstraint.activate([
            headerIconWrap.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            headerIconWrap.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerIconWrap.widthAnchor.constraint(equalToConstant: 40),
            headerIconWrap.heightAnchor.constraint(equalToConstant: 40),
            headerIcon.centerXAnchor.constraint(equalTo: headerIconWrap.centerXAnchor),
            headerIcon.centerYAnchor.constraint(equalTo: headerIconWrap.centerYAnchor),
            headerIcon.widthAnchor.constraint(equalToConstant: 20),
            headerIcon.heightAnchor.constraint(equalToConstant: 20),
            headerTitle.centerYAnchor.constraint(equalTo: headerIconWrap.centerYAnchor),
            headerTitle.leadingAnchor.constraint(equalTo: headerIconWrap.trailingAnchor, constant: 11),
            closeButton.centerYAnchor.constraint(equalTo: headerIconWrap.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
            searchBox.topAnchor.constraint(equalTo: headerIconWrap.bottomAnchor, constant: 12),
            searchBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            searchBox.heightAnchor.constraint(equalToConstant: 48),
            searchIcon.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 14),
            searchIcon.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 18),
            searchIcon.heightAnchor.constraint(equalToConstant: 18),
            searchSpinner.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 14),
            searchSpinner.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 41),
            searchField.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: searchBox.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchBox.bottomAnchor),
            listContainer.topAnchor.constraint(equalTo: searchBox.bottomAnchor, constant: 10),
            listContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            listContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            listContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            listScrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            listScrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            listScrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            listScrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            rowsStack.topAnchor.constraint(equalTo: listScrollView.contentLayoutGuide.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: listScrollView.contentLayoutGuide.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: listScrollView.contentLayoutGuide.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: listScrollView.contentLayoutGuide.bottomAnchor),
            rowsStack.widthAnchor.constraint(equalTo: listScrollView.frameLayoutGuide.widthAnchor),
            stateView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            stateCircle.topAnchor.constraint(equalTo: stateView.topAnchor, constant: 28),
            stateCircle.centerXAnchor.constraint(equalTo: stateView.centerXAnchor),
            stateCircle.widthAnchor.constraint(equalToConstant: 54),
            stateCircle.heightAnchor.constraint(equalToConstant: 54),
            stateIcon.centerXAnchor.constraint(equalTo: stateCircle.centerXAnchor),
            stateIcon.centerYAnchor.constraint(equalTo: stateCircle.centerYAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 25),
            stateIcon.heightAnchor.constraint(equalToConstant: 25),
            stateSpinner.centerXAnchor.constraint(equalTo: stateCircle.centerXAnchor),
            stateSpinner.centerYAnchor.constraint(equalTo: stateCircle.centerYAnchor),
            stateTitle.topAnchor.constraint(equalTo: stateCircle.bottomAnchor, constant: 11),
            stateTitle.leadingAnchor.constraint(equalTo: stateView.leadingAnchor, constant: 20),
            stateTitle.trailingAnchor.constraint(equalTo: stateView.trailingAnchor, constant: -20),
            stateSubtitle.topAnchor.constraint(equalTo: stateTitle.bottomAnchor, constant: 4),
            stateSubtitle.leadingAnchor.constraint(equalTo: stateView.leadingAnchor, constant: 20),
            stateSubtitle.trailingAnchor.constraint(equalTo: stateView.trailingAnchor, constant: -20),
            stateRetryButton.topAnchor.constraint(equalTo: stateSubtitle.bottomAnchor, constant: 8),
            stateRetryButton.centerXAnchor.constraint(equalTo: stateView.centerXAnchor),
            stateRetryButton.bottomAnchor.constraint(equalTo: stateView.bottomAnchor),
        ])
    }

    @objc private func didTapClose() {
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func didTapStateRetry() {
        runSearch(query: lastQuery)
    }

    @objc private func searchFieldChanged() {
        // 250ms 防抖 + 序号防旧响应（与网页搜索同款）。
        searchTimer?.invalidate()
        let text = searchField.text ?? ""
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.runSearch(query: text)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        searchTimer?.invalidate()
        runSearch(query: textField.text ?? "")
        return true
    }

    /// 四态：init（未搜）/ loading（框内转圈 + 列表态）/ none / fail；有结果时态视图隐藏。
    private func showState(kind: String, query: String) {
        if kind == "results" {
            stateView.isHidden = true
            listScrollView.isHidden = false
            return
        }
        stateView.isHidden = false
        listScrollView.isHidden = true
        stateSpinner.stopAnimating()
        stateIcon.isHidden = false
        stateRetryButton.isHidden = true
        if kind == "loading" {
            stateIcon.isHidden = true
            stateSpinner.startAnimating()
            stateTitle.text = "正在找"
            stateSubtitle.text = "马上就来"
        } else if kind == "none" {
            stateIcon.image = UIImage(systemName: "magnifyingglass")
            stateTitle.text = "没有找到「" + query + "」"
            stateSubtitle.text = "检查一下昵称或 @用户名是否正确"
        } else if kind == "fail" {
            stateIcon.image = UIImage(systemName: "magnifyingglass")
            stateTitle.text = "搜索失败"
            stateSubtitle.text = "网络好像不太顺"
            stateRetryButton.isHidden = false
        } else {
            stateIcon.image = UIImage(systemName: "at")
            stateTitle.text = "写给某个人"
            stateSubtitle.text = "这篇 7 天后才公开"
        }
    }

    /// 搜索框内转圈：图标位换 spinner（网页 addrSetIconBusy 同款），不再居中大转圈。
    private func setSearchBusy(_ busy: Bool) {
        if busy {
            searchIcon.isHidden = true
            searchSpinner.startAnimating()
        } else {
            searchSpinner.stopAnimating()
            searchIcon.isHidden = false
        }
    }

    private func runSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            users = []
            lastQuery = ""
            setSearchBusy(false)
            renderRows()
            showState(kind: "init", query: "")
            return
        }
        lastQuery = trimmed
        searchSeq += 1
        let seq = searchSeq
        setSearchBusy(true)
        showState(kind: "loading", query: trimmed)
        BearyAPI.shared.search(q: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, seq == self.searchSeq else { return }
                self.setSearchBusy(false)
                switch result {
                case .success(let resp):
                    // 网页同款：结果过滤掉本人。
                    let myUserId = SessionManager.shared.currentUser?.id
                    var filtered: [SearchUser] = []
                    for user in resp.users ?? [] {
                        if let userId = user.id, let mine = myUserId, userId == mine {
                            continue
                        }
                        filtered.append(user)
                    }
                    self.users = filtered
                    self.renderRows()
                    if filtered.isEmpty {
                        self.showState(kind: "none", query: trimmed)
                    } else {
                        self.showState(kind: "results", query: trimmed)
                    }
                case .failure:
                    self.users = []
                    self.renderRows()
                    self.showState(kind: "fail", query: trimmed)
                }
            }
        }
    }

    private func renderRows() {
        for arranged in rowsStack.arrangedSubviews {
            rowsStack.removeArrangedSubview(arranged)
            arranged.removeFromSuperview()
        }
        rowButtons = []
        rowUsers = users
        for index in 0..<users.count {
            let user = users[index]
            let row = UIButton(type: .custom)
            row.translatesAutoresizingMaskIntoConstraints = false
            let avatarView = UIImageView()
            avatarView.translatesAutoresizingMaskIntoConstraints = false
            avatarView.contentMode = .scaleAspectFill
            avatarView.clipsToBounds = true
            avatarView.layer.cornerRadius = 22
            avatarView.layer.masksToBounds = true
            let fallbackLabel = UILabel()
            fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
            fallbackLabel.font = UIFont.boldSystemFont(ofSize: 16)
            fallbackLabel.textColor = BearyColors.orange
            fallbackLabel.backgroundColor = BearyColors.orange.withAlphaComponent(0.18)
            fallbackLabel.textAlignment = .center
            fallbackLabel.layer.cornerRadius = 22
            fallbackLabel.layer.masksToBounds = true
            let nameLabel = UILabel()
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.font = UIFont.systemFont(ofSize: 15, weight: .bold)
            nameLabel.textColor = BearyColors.ink
            let handleLabel = UILabel()
            handleLabel.translatesAutoresizingMaskIntoConstraints = false
            handleLabel.font = UIFont.systemFont(ofSize: 12.5)
            handleLabel.textColor = BearyColors.gray
            let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.tintColor = BearyColors.gray
            chevron.contentMode = .scaleAspectFit
            let name: String
            if let display = user.displayName {
                name = display
            } else if let handle = user.handle {
                name = "@" + handle
            } else {
                name = "beary 用户"
            }
            nameLabel.text = name
            if let handle = user.handle {
                handleLabel.text = "@" + handle
                handleLabel.isHidden = false
            } else {
                handleLabel.isHidden = true
            }
            if let avatarPath = user.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
                avatarView.bearySetImage(url: url, placeholder: nil)
                avatarView.isHidden = false
                fallbackLabel.isHidden = true
            } else {
                avatarView.isHidden = true
                fallbackLabel.isHidden = false
                fallbackLabel.text = String(name.prefix(1)).uppercased()
            }
            let separator = UIView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.backgroundColor = BearyColors.line
            separator.isHidden = (index == 0)
            row.addSubview(avatarView)
            row.addSubview(fallbackLabel)
            row.addSubview(nameLabel)
            row.addSubview(handleLabel)
            row.addSubview(chevron)
            row.addSubview(separator)
            NSLayoutConstraint.activate([
                avatarView.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                avatarView.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
                avatarView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                avatarView.widthAnchor.constraint(equalToConstant: 44),
                avatarView.heightAnchor.constraint(equalToConstant: 44),
                fallbackLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),
                fallbackLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -10),
                fallbackLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                fallbackLabel.widthAnchor.constraint(equalToConstant: 44),
                fallbackLabel.heightAnchor.constraint(equalToConstant: 44),
                nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
                nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 68),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
                handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
                handleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 68),
                handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
                handleLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -12),
                chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                chevron.widthAnchor.constraint(equalToConstant: 16),
                chevron.heightAnchor.constraint(equalToConstant: 16),
                separator.topAnchor.constraint(equalTo: row.topAnchor),
                separator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 68),
                separator.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                separator.heightAnchor.constraint(equalToConstant: 0.5),
            ])
            row.addTarget(self, action: #selector(didTapRow(_:)), for: .touchUpInside)
            row.accessibilityLabel = name
            rowsStack.addArrangedSubview(row)
            rowButtons.append(row)
        }
        // 行按钮与 rowUsers 按顺序对应（渲染时同步重建）；点行时按按钮身份取用户。
    }

    private var rowButtons: [UIButton] = []
    private var rowUsers: [SearchUser] = []

    @objc private func didTapRow(_ sender: UIButton) {
        var picked: SearchUser?
        for index in 0..<rowButtons.count {
            if index < rowUsers.count && rowButtons[index] == sender {
                picked = rowUsers[index]
            }
        }
        guard let user = picked else { return }
        onPick?(user)
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
