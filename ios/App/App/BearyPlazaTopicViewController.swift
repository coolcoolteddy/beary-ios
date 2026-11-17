import UIKit

// ===== 今日话题页（轮播话题卡点开进这里）=====
// 相关公开日记 + 写一篇入口。相关日记复用已有搜索接口
// （BearyAPI.search，首屏缓存本身已按身份分桶）；调用方仍按
// identity_safe_async_data 口径：发起时抓账号 id、会话代次与请求序号，
// 回包先比对——切号的晚到回包直接丢弃、按当前身份重发，绝不把
// 旧身份的搜索结果渲染给新身份。写一篇走容器 onCompose（未登录时
// presentComposer 内的登录门承接）；本页不直接碰编辑器。
// 行点按：先 dismiss 本页，再走 onEntrySelected 进详情（详情由容器
// 从根页 present，本页不叠 present）。

final class BearyPlazaTopicViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    var onEntrySelected: ((Entry) -> Void)?
    var onCompose: (() -> Void)?

    private let topic: BearyPlazaCarouselTopic

    private enum LoadState {
        case loading
        case loaded
        case empty
        case failed
    }

    private var relatedEntries: [Entry] = []
    private var loadState: LoadState = .loading
    /// 请求序号：每次发起 +1，旧回包一律丢弃（切段/重搜/切号后晚到）。
    private var searchSequence = 0
    private var currentSearchTask: URLSessionDataTask?

    private let topBar = UIView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let headerView = UIView()
    private var headerHeight: CGFloat = 0

    init(topic: BearyPlazaCarouselTopic) {
        self.topic = topic
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        currentSearchTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        // 顶栏：全屏页统一左箭头返回（与盲盒流程页同口径）。
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        let backButton = BearyHit44Button(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        if let back = BearyIconImages.image(named: "icon_back", pointSize: 24) {
            backButton.setImage(back, for: .normal)
        } else {
            backButton.setTitle("返回", for: .normal)
        }
        backButton.tintColor = BearyColors.ink
        backButton.setTitleColor(BearyColors.ink, for: .normal)
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        topBar.addSubview(backButton)
        let topTitle = UILabel()
        topTitle.translatesAutoresizingMaskIntoConstraints = false
        topTitle.text = "今日话题"
        topTitle.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        topTitle.adjustsFontForContentSizeCategory = true
        topTitle.textColor = BearyColors.ink
        topBar.addSubview(topTitle)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(BearyPlazaTopicRowCell.self, forCellReuseIdentifier: "BearyPlazaTopicRowCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "BearyPlazaTopicStateCell")
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            topTitle.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            topTitle.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        buildHeaderView()
        loadRelated()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutHeaderView()
    }

    @objc private func closeTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }

    // MARK: - 表头（话题标题 + 提问 + 写一篇 + 相关日记小节标题）

    private func buildHeaderView() {
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = topic.title
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 20, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0

        let questionLabel = UILabel()
        questionLabel.translatesAutoresizingMaskIntoConstraints = false
        questionLabel.text = topic.question
        questionLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        questionLabel.adjustsFontForContentSizeCategory = true
        questionLabel.textColor = BearyColors.gray
        questionLabel.numberOfLines = 0

        let write = BearyHit44Button(type: .custom)
        write.translatesAutoresizingMaskIntoConstraints = false
        write.setTitle("写一篇", for: .normal)
        write.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        write.backgroundColor = BearyColors.orange
        write.setTitleColor(BearyColors.onBrand, for: .normal)
        write.layer.cornerRadius = BearyCorners.single
        write.addTarget(self, action: #selector(writeTapped), for: .touchUpInside)
        write.bearyAddPressFeedback()
        write.accessibilityLabel = "写一篇"

        let sectionLabel = UILabel()
        sectionLabel.translatesAutoresizingMaskIntoConstraints = false
        sectionLabel.text = "相关日记"
        sectionLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        sectionLabel.adjustsFontForContentSizeCategory = true
        sectionLabel.textColor = BearyColors.ink

        headerView.addSubview(titleLabel)
        headerView.addSubview(questionLabel)
        headerView.addSubview(write)
        headerView.addSubview(sectionLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            questionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            questionLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            questionLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            write.topAnchor.constraint(equalTo: questionLabel.bottomAnchor, constant: 16),
            write.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            write.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            write.heightAnchor.constraint(equalToConstant: 44),
            sectionLabel.topAnchor.constraint(equalTo: write.bottomAnchor, constant: 20),
            sectionLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 16),
            sectionLabel.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -16),
            sectionLabel.bottomAnchor.constraint(equalTo: headerView.bottomAnchor, constant: -8),
        ])
        tableView.tableHeaderView = headerView
    }

    private func layoutHeaderView() {
        let width = tableView.bounds.width
        guard width > 0 else { return }
        headerView.frame.size.width = width
        let height = headerView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        if abs(height - headerHeight) > 0.5 || tableView.tableHeaderView == nil {
            headerHeight = height
            headerView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            tableView.tableHeaderView = headerView
        }
    }

    @objc private func writeTapped() {
        // 先关本页再开编辑器（编辑器由容器从根页 present，不叠 present）。
        dismiss(animated: false) { [weak self] in
            self?.onCompose?()
        }
    }

    // MARK: - 相关日记（复用搜索接口，按身份守卫回包）

    private func loadRelated() {
        searchSequence += 1
        let sequence = searchSequence
        // 发起时抓取身份：账号 id、会话代次与请求序号跟回调一起带走，回调里不读当前身份。
        let requestAccountId = SessionManager.shared.currentUser?.id
        let requestEpoch = SessionManager.shared.currentSessionGeneration
        currentSearchTask?.cancel()
        loadState = .loading
        relatedEntries = []
        tableView.reloadData()
        tryKeyword(at: 0, sequence: sequence, requestAccountId: requestAccountId, requestEpoch: requestEpoch)
    }

    private func tryKeyword(at index: Int, sequence: Int, requestAccountId: Int?, requestEpoch: Int) {
        guard index < topic.keywords.count else {
            // 关键词都试过仍无结果：空态（不谎报、不编造）。
            DispatchQueue.main.async { [weak self] in
                guard let self = self, sequence == self.searchSequence else { return }
                self.loadState = .empty
                self.tableView.reloadData()
            }
            return
        }
        let keyword = topic.keywords[index]
        currentSearchTask = BearyAPI.shared.search(q: keyword) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 序号守卫：旧请求回包直接丢弃。
                guard sequence == self.searchSequence else { return }
                // 代次守卫：401/退出/切号推进代次后，旧回包直接丢弃、按当前身份重发。
                guard requestEpoch == SessionManager.shared.currentSessionGeneration else {
                    self.loadRelated()
                    return
                }
                // 身份复核：发起时的账号与当前不一致，丢弃本次结果、按当前身份重发。
                guard requestAccountId == SessionManager.shared.currentUser?.id else {
                    self.loadRelated()
                    return
                }
                switch result {
                case .success(let data):
                    let entries = (data.entries ?? [])
                        .filter { BearyEphemeral.isEffectivelyPublic($0) }
                    if entries.isEmpty {
                        self.tryKeyword(at: index + 1, sequence: sequence, requestAccountId: requestAccountId, requestEpoch: requestEpoch)
                        return
                    }
                    self.relatedEntries = Array(entries.prefix(20))
                    self.loadState = .loaded
                    self.tableView.reloadData()
                case .failure:
                    self.loadState = .failed
                    self.tableView.reloadData()
                }
            }
        }
    }

    // MARK: - UITableViewDataSource / Delegate

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch loadState {
        case .loading, .failed, .empty: return 1
        case .loaded: return relatedEntries.count
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch loadState {
        case .loading:
            let cell = tableView.dequeueReusableCell(withIdentifier: "BearyPlazaTopicStateCell", for: indexPath)
            cell.textLabel?.text = "正在找相关日记…"
            cell.textLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            cell.textLabel?.textColor = BearyColors.gray
            cell.textLabel?.textAlignment = .center
            cell.selectionStyle = .none
            return cell
        case .failed:
            let cell = tableView.dequeueReusableCell(withIdentifier: "BearyPlazaTopicStateCell", for: indexPath)
            cell.textLabel?.text = "加载失败，点按重试"
            cell.textLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            cell.textLabel?.textColor = BearyColors.gray
            cell.textLabel?.textAlignment = .center
            cell.selectionStyle = .none
            return cell
        case .empty:
            let cell = tableView.dequeueReusableCell(withIdentifier: "BearyPlazaTopicStateCell", for: indexPath)
            cell.textLabel?.text = "还没有人写过这个话题，来写第一篇吧"
            cell.textLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
            cell.textLabel?.textColor = BearyColors.gray
            cell.textLabel?.textAlignment = .center
            cell.textLabel?.numberOfLines = 0
            cell.selectionStyle = .none
            return cell
        case .loaded:
            let cell = tableView.dequeueReusableCell(withIdentifier: "BearyPlazaTopicRowCell", for: indexPath) as! BearyPlazaTopicRowCell
            cell.configure(entry: relatedEntries[indexPath.row])
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch loadState {
        case .failed:
            loadRelated()
        case .loaded:
            let entry = relatedEntries[indexPath.row]
            dismiss(animated: false) { [weak self] in
                self?.onEntrySelected?(entry)
            }
        case .loading, .empty:
            break
        }
    }
}

// MARK: - 相关日记行（轻量行：标题 + 正文首行 + 作者 · 时间）

final class BearyPlazaTopicRowCell: UITableViewCell {

    private let titleLabel = UILabel()
    private let snippetLabel = UILabel()
    private let metaLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .default

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail

        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        snippetLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        snippetLabel.adjustsFontForContentSizeCategory = true
        snippetLabel.textColor = BearyColors.gray
        snippetLabel.numberOfLines = 2
        snippetLabel.lineBreakMode = .byTruncatingTail

        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = BearyColors.gray
        metaLabel.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [titleLabel, snippetLabel, metaLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(entry: Entry) {
        titleLabel.text = BearyPlazaCarouselText.displayTitle(for: entry)
        var snippet = ""
        if let content = entry.content {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    snippet = trimmed
                    break
                }
            }
        }
        snippetLabel.text = snippet
        snippetLabel.isHidden = snippet.isEmpty
        var parts: [String] = []
        if let name = entry.authorName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            parts.append(name)
        }
        let dateText = BlindBoxDate.displayString(ms: entry.publishedAt ?? entry.createdAt)
        if !dateText.isEmpty {
            parts.append(dateText)
        }
        metaLabel.text = parts.joined(separator: " · ")
        metaLabel.isHidden = parts.isEmpty
        accessibilityLabel = titleLabel.text
    }
}
