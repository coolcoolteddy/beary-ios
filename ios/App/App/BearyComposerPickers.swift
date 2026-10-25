import UIKit

// ===== 编辑器两个选择器（主线闭环第一块）=====
// 写给选人：调 GET /beary/api/search?q=，只取 users 组（display_name/handle 匹配，≤8 条，
// 与网页搜索同口径）；点行即回传 SearchUser，调用方负责写给标签与通知开关。
// 引用日记：调 GET /beary/api/entries?scope=timeline&limit=50（与网页引用面板同款：
// 只列自己的时间线，因为服务端 validQuoteId 只接受本人日记，赞过/收藏的他人日记引用会被服务端静默丢弃，
// 所以不做 liked/saved 两个 tab）。
// 约束：部署目标 iOS 15.0、Swift 5.0——只用闭包回调，不用 async/await，不用 if-let 简写。

// MARK: - 写给选人

final class BearyRecipientPickerViewController: UIViewController {

    /// 点行回传（调用方写 selectedRecipient；本页随后自行 dismiss）。
    var onPick: ((SearchUser) -> Void)?

    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var users: [SearchUser] = []
    private var searchTimer: Timer?
    private var searchSeq = 0
    private var hasSearched = false
    private var searchFailed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        title = "选择收信人"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(didTapCancel))
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.placeholder = "搜名字或 @handle"
        searchBar.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = UIFont.systemFont(ofSize: 15)
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        view.addSubview(searchBar)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        searchBar.becomeFirstResponder()
    }

    deinit {
        searchTimer?.invalidate()
    }

    @objc private func didTapCancel() {
        navigationController?.dismiss(animated: true)
    }

    private func runSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            users = []
            hasSearched = false
            emptyLabel.isHidden = true
            spinner.stopAnimating()
            tableView.reloadData()
            return
        }
        searchSeq += 1
        let seq = searchSeq
        hasSearched = true
        searchFailed = false
        emptyLabel.isHidden = true
        spinner.startAnimating()
        BearyAPI.shared.search(q: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, seq == self.searchSeq else { return }
                self.spinner.stopAnimating()
                switch result {
                case .success(let resp):
                    self.users = resp.users ?? []
                    self.searchFailed = false
                case .failure:
                    self.users = []
                    self.searchFailed = true
                }
                self.emptyLabel.isHidden = !self.users.isEmpty
                self.emptyLabel.text = self.users.isEmpty ? (self.searchFailed ? "搜索失败，请重试" : "没有找到") : nil
                self.tableView.reloadData()
            }
        }
    }
}

extension BearyRecipientPickerViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // 250ms 防抖 + 序号防旧响应（与网页搜索同款）。
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.runSearch(query: searchText)
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        searchTimer?.invalidate()
        runSearch(query: searchBar.text ?? "")
    }
}

extension BearyRecipientPickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return users.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var cell = tableView.dequeueReusableCell(withIdentifier: "UserCell")
        if cell == nil {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: "UserCell")
        }
        guard let rowCell = cell else { return UITableViewCell() }
        let user = users[indexPath.row]
        let name: String
        if let display = user.displayName {
            name = display
        } else if let handle = user.handle {
            name = "@" + handle
        } else {
            name = "用户"
        }
        rowCell.textLabel?.text = name
        if let handle = user.handle, user.displayName != nil {
            rowCell.detailTextLabel?.text = "@" + handle
        } else {
            rowCell.detailTextLabel?.text = nil
        }
        rowCell.textLabel?.font = UIFont.systemFont(ofSize: 16)
        rowCell.textLabel?.textColor = BearyColors.ink
        rowCell.detailTextLabel?.font = UIFont.systemFont(ofSize: 13)
        rowCell.detailTextLabel?.textColor = BearyColors.gray
        return rowCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        let user = users[indexPath.row]
        onPick?(user)
        navigationController?.dismiss(animated: true)
    }
}

// MARK: - 引用日记（只列自己的时间线）

final class BearyQuotePickerViewController: UIViewController {

    /// 点行回传（调用方写 selectedQuote；本页随后自行 dismiss）。
    var onPick: ((Entry) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retryButton = UIButton(type: .system)
    private var entries: [Entry] = []
    private var loadFailed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        title = "引用日记"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "取消", style: .plain, target: self, action: #selector(didTapCancel))
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = UIFont.systemFont(ofSize: 15)
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.text = "还没有可引用的日记"
        emptyLabel.isHidden = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = BearyColors.gray
        spinner.hidesWhenStopped = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("加载失败，点击重试", for: .normal)
        retryButton.setTitleColor(BearyColors.blue, for: .normal)
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(didTapRetry), for: .touchUpInside)
        view.addSubview(tableView)
        view.addSubview(emptyLabel)
        view.addSubview(spinner)
        view.addSubview(retryButton)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        loadQuotes()
    }

    @objc private func didTapCancel() {
        navigationController?.dismiss(animated: true)
    }

    @objc private func didTapRetry() {
        loadQuotes()
    }

    private func loadQuotes() {
        loadFailed = false
        retryButton.isHidden = true
        emptyLabel.isHidden = true
        spinner.startAnimating()
        BearyAPI.shared.fetchEntries(scope: .timeline, limit: 50) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.spinner.stopAnimating()
                switch result {
                case .success(let list):
                    self.entries = list.entries ?? []
                    self.emptyLabel.isHidden = !self.entries.isEmpty
                    self.tableView.reloadData()
                case .failure:
                    self.loadFailed = true
                    self.retryButton.isHidden = false
                }
            }
        }
    }
}

extension BearyQuotePickerViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return entries.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var cell = tableView.dequeueReusableCell(withIdentifier: "QuoteCell")
        if cell == nil {
            cell = UITableViewCell(style: .subtitle, reuseIdentifier: "QuoteCell")
        }
        guard let rowCell = cell else { return UITableViewCell() }
        let entry = entries[indexPath.row]
        rowCell.textLabel?.numberOfLines = 2
        rowCell.textLabel?.font = UIFont.systemFont(ofSize: 15)
        rowCell.textLabel?.textColor = BearyColors.ink
        rowCell.textLabel?.text = entry.content ?? ""
        if let ms = entry.createdAt {
            rowCell.detailTextLabel?.text = BearyText.timeString(ms: ms)
        } else {
            rowCell.detailTextLabel?.text = nil
        }
        rowCell.detailTextLabel?.font = UIFont.systemFont(ofSize: 13)
        rowCell.detailTextLabel?.textColor = BearyColors.gray
        return rowCell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: !UIAccessibility.isReduceMotionEnabled)
        let entry = entries[indexPath.row]
        onPick?(entry)
        navigationController?.dismiss(animated: true)
    }
}
