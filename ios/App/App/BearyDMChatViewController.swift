import UIKit

// MARK: - 好友第一期（私信）：会话页（聊天页，modal 全屏）
//
// 只限互关好友、纯文字：无图片按钮、无引用、无群聊、无撤回/编辑。
// 进入会话即调 dm/read 清未读；对方发来新消息时沿用现有列表刷新口径
//（下拉刷新 + 重进），不另搭长连接、不搭推送。
// 已读回执不显示给对方：read_at 只用于自己未读计数，本页不画任何已读态。
// 取关/拉黑后 history/send 一律 403：历史 403 时页内显“该会话已关闭”并
// 禁用输入；发送 403 只 toast，不泄露拉黑方向。
// 发送成功不做乐观假态：服务端确认后重拉最新页再落行（与点赞“服务端确认”
// 口径一致）；失败保留输入框草稿，只 toast。

final class BearyDMChatViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UITextViewDelegate {

    /// 对方（id 必填；容器只在 id 存在时建页）。
    let peer: BearyAPI.FriendUser
    /// 未登录时调用：容器接线到登录门。
    var onRequireLogin: (() -> Void)?
    /// 顶栏关闭点按：容器接线到 dismiss。
    var onBack: (() -> Void)?
    /// 页关闭后调用：容器接线刷新会话列表与通知未读（会话页不直接碰别页模型）。
    var onClosed: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()
    private let inputBar = UIView()
    private let inputTextView = UITextView()
    private let sendButton = UIButton(type: .system)
    private var inputBarBottomConstraint: NSLayoutConstraint?
    private var messages: [BearyAPI.DMMessage] = []
    private var loading = false
    private var loadingOlder = false
    private var hasMoreOlder = false
    private var loadFailed = false
    private var sessionClosed = false
    private var sending = false
    private var didMarkRead = false

    init(peer: BearyAPI.FriendUser) {
        self.peer = peer
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        let closeButton = UIButton(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 20), for: .normal)
        closeButton.tintColor = BearyColors.ink
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        topBar.addSubview(closeButton)
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = (peer.displayName?.isEmpty == false) ? peer.displayName! : "Beary 用户"
        topBar.addSubview(titleLabel)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyDMMessageCell.self, forCellReuseIdentifier: "dmMessageCell")
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
        tableView.refreshControl = refresh
        view.addSubview(tableView)

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        view.addSubview(emptyLabel)

        // 输入条：纯文字，无图片按钮；发送钮墨色 pill，空输入时禁用。
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.backgroundColor = BearyColors.bg
        view.addSubview(inputBar)
        let topLine = UIView()
        topLine.translatesAutoresizingMaskIntoConstraints = false
        topLine.backgroundColor = BearyColors.line
        inputBar.addSubview(topLine)
        inputTextView.translatesAutoresizingMaskIntoConstraints = false
        inputTextView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        inputTextView.adjustsFontForContentSizeCategory = true
        inputTextView.textColor = BearyColors.ink
        inputTextView.backgroundColor = BearyColors.faint
        inputTextView.layer.cornerRadius = 16
        inputTextView.clipsToBounds = true
        inputTextView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        inputTextView.delegate = self
        inputTextView.isScrollEnabled = true
        inputBar.addSubview(inputTextView)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle("发送", for: .normal)
        sendButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        sendButton.titleLabel?.adjustsFontForContentSizeCategory = true
        sendButton.setTitleColor(BearyColors.bg, for: .normal)
        sendButton.backgroundColor = BearyColors.ink
        sendButton.layer.cornerRadius = 16
        sendButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 16, bottom: 6, right: 16)
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        sendButton.bearyAddPressFeedback()
        sendButton.isEnabled = false
        sendButton.alpha = 0.6
        inputBar.addSubview(sendButton)

        inputBarBottomConstraint = inputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        inputBarBottomConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: inputBar.topAnchor),
            topLine.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            inputTextView.topAnchor.constraint(equalTo: inputBar.topAnchor, constant: 9),
            inputTextView.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor, constant: 16),
            inputTextView.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -9),
            inputTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            sendButton.leadingAnchor.constraint(equalTo: inputTextView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -16),
            sendButton.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -9),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        loadLatest()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // modal dismiss 后容器刷新会话列表未读与通知未读（本页不直接碰别页模型）。
        onClosed?()
    }

    @objc private func closeTapped() {
        onBack?()
    }

    @objc private func refreshPulled() {
        loadLatest()
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        guard let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let height = max(0, frame.height - view.safeAreaInsets.bottom)
        inputBarBottomConstraint?.constant = -height
        view.layoutIfNeeded()
        // 不抢滚动位：输入条顶起后表高缩小，旧 offset 自然保留，正在翻旧消息
        // 的用户不被拽到底；新消息发送成功后由 loadLatest 的 wasAtBottom 分支处理。
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        inputBarBottomConstraint?.constant = 0
        view.layoutIfNeeded()
    }

    func textViewDidChange(_ textView: UITextView) {
        updateSendButton()
    }

    private func updateSendButton() {
        let hasText = !inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.isEnabled = hasText && !sending && !sessionClosed
        sendButton.alpha = sendButton.isEnabled ? 1 : 0.6
    }

    private func scrollToBottomIfNeeded() {
        guard !messages.isEmpty else { return }
        tableView.layoutIfNeeded()
        let path = IndexPath(row: messages.count - 1, section: 0)
        tableView.scrollToRow(at: path, at: .bottom, animated: false)
    }

    private func updateEmptyState() {
        if sessionClosed {
            emptyLabel.text = "该会话已关闭"
            emptyLabel.isHidden = false
        } else if loadFailed && messages.isEmpty {
            emptyLabel.text = "加载失败，下拉重试"
            emptyLabel.isHidden = false
        } else if messages.isEmpty {
            emptyLabel.text = "还没有消息\n发第一条纯文字消息吧"
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func markReadIfNeeded() {
        guard let userId = peer.id, !didMarkRead else { return }
        didMarkRead = true
        // 失败静默：未读数下次进会话/会话列表时再对齐，不弹 toast 打断聊天。
        BearyAPI.shared.markDMRead(userId: userId) { _ in }
    }

    /// 最新页：服务端按 id 倒序下发，展示时反转为正序；成功后清未读。
    private func loadLatest() {
        guard let userId = peer.id, !loading else { return }
        guard SessionManager.shared.isLoggedIn else {
            tableView.refreshControl?.endRefreshing()
            onRequireLogin?()
            return
        }
        loading = true
        loadFailed = false
        let wasAtBottom: Bool = {
            guard !messages.isEmpty else { return true }
            let offsetY = tableView.contentOffset.y + tableView.bounds.height
            return offsetY >= tableView.contentSize.height - 80
        }()
        BearyAPI.shared.fetchDMHistory(userId: userId, limit: 30) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                self.tableView.refreshControl?.endRefreshing()
                switch result {
                case .success(let history):
                    let fetched = history.resolvedMessages.reversed()
                    self.messages = Array(fetched)
                    self.hasMoreOlder = history.resolvedMessages.count >= 30
                    self.loadFailed = false
                    self.updateEmptyState()
                    self.tableView.reloadData()
                    if wasAtBottom { self.scrollToBottomIfNeeded() }
                    self.markReadIfNeeded()
                case .failure(let error):
                    if case .http(403, _) = error {
                        self.sessionClosed = true
                        self.inputTextView.isEditable = false
                        self.updateSendButton()
                    }
                    self.loadFailed = true
                    self.updateEmptyState()
                }
            }
        }
    }

    /// 向上翻 older：before_id 取最旧一条 id；前插后按增量高度修正 offset，
    /// 不跳视口（与时间线分页同口径）。
    private func loadOlder() {
        guard let userId = peer.id, !loadingOlder, hasMoreOlder,
              let oldestId = messages.first?.id else { return }
        loadingOlder = true
        let oldHeight = tableView.contentSize.height
        let oldOffsetY = tableView.contentOffset.y
        BearyAPI.shared.fetchDMHistory(userId: userId, beforeId: oldestId, limit: 30) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loadingOlder = false
                switch result {
                case .success(let history):
                    let older = Array(history.resolvedMessages.reversed())
                    self.hasMoreOlder = history.resolvedMessages.count >= 30
                    self.messages.insert(contentsOf: older, at: 0)
                    self.tableView.reloadData()
                    self.tableView.layoutIfNeeded()
                    let delta = self.tableView.contentSize.height - oldHeight
                    self.tableView.contentOffset = CGPoint(x: 0, y: oldOffsetY + delta)
                case .failure:
                    break
                }
            }
        }
    }

    @objc private func sendTapped() {
        guard let userId = peer.id, !sending, !sessionClosed else { return }
        let body = inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        guard body.count <= 2000 else {
            BearyToast.show(in: view, message: "消息最多 2000 字")
            return
        }
        guard SessionManager.shared.isLoggedIn else {
            onRequireLogin?()
            return
        }
        sending = true
        updateSendButton()
        BearyAPI.shared.sendDM(userId: userId, body: body) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sending = false
                switch result {
                case .success:
                    self.inputTextView.text = ""
                    self.updateSendButton()
                    // 服务端确认后重拉最新页再落行，不做乐观假态。
                    self.loadLatest()
                    self.scrollToBottomIfNeeded()
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .http(403, _) = error {
                        self.sessionClosed = true
                        self.inputTextView.isEditable = false
                        self.updateSendButton()
                        self.updateEmptyState()
                        BearyToast.show(in: self.view, message: "发送失败，请重试")
                    } else {
                        BearyToast.show(in: self.view, message: "发送失败，请重试")
                    }
                    self.updateSendButton()
                }
            }
        }
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "dmMessageCell", for: indexPath) as! BearyDMMessageCell
        let message = messages[indexPath.row]
        let isMine = message.senderId != nil && message.senderId == SessionManager.shared.currentUser?.id
        cell.configure(message: message, isMine: isMine)
        return cell
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // 仅用户手势滚动到顶部附近且还有 older 时翻页：程序化滚动（首拉后
        // 回到底部、reloadData 布局抖动）不得触发，否则首屏会连翻 older。
        // 下拉刷新控件也在顶部，阈值取 120，与下拉手势不打架（下拉刷新在途
        // 时 loadOlder 的 loadingOlder 守卫互斥）。
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        if scrollView.contentOffset.y < 120 {
            loadOlder()
        }
    }
}

// MARK: - 消息 Cell（左右气泡 + 时间；无自绘图形）

private final class BearyDMMessageCell: UITableViewCell {

    private let mineStack = UIStackView()
    private let theirsStack = UIStackView()
    private let mineBubble = UIView()
    private let theirsBubble = UIView()
    private let mineTextLabel = UILabel()
    private let theirsTextLabel = UILabel()
    private let mineTimeLabel = UILabel()
    private let theirsTimeLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .none

        for (stack, bubble, textLabel, timeLabel, isMine) in [
            (mineStack, mineBubble, mineTextLabel, mineTimeLabel, true),
            (theirsStack, theirsBubble, theirsTextLabel, theirsTimeLabel, false),
        ] as [(UIStackView, UIView, UILabel, UILabel, Bool)] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.axis = .vertical
            stack.spacing = 2
            stack.alignment = isMine ? .trailing : .leading
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubble.layer.cornerRadius = 16
            bubble.clipsToBounds = true
            bubble.backgroundColor = isMine ? BearyColors.orange : BearyColors.faint
            textLabel.translatesAutoresizingMaskIntoConstraints = false
            textLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
            textLabel.adjustsFontForContentSizeCategory = true
            textLabel.textColor = isMine ? .white : BearyColors.ink
            textLabel.numberOfLines = 0
            timeLabel.translatesAutoresizingMaskIntoConstraints = false
            timeLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
            timeLabel.adjustsFontForContentSizeCategory = true
            timeLabel.textColor = BearyColors.gray
            bubble.addSubview(textLabel)
            NSLayoutConstraint.activate([
                textLabel.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 8),
                textLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
                textLabel.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
                textLabel.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -8),
            ])
            stack.addArrangedSubview(bubble)
            stack.addArrangedSubview(timeLabel)
            contentView.addSubview(stack)
        }
        NSLayoutConstraint.activate([
            mineStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            mineStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            mineStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 104),
            mineStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            theirsStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            theirsStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            theirsStack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -104),
            theirsStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        mineTextLabel.text = nil
        theirsTextLabel.text = nil
        mineTimeLabel.text = nil
        theirsTimeLabel.text = nil
    }

    func configure(message: BearyAPI.DMMessage, isMine: Bool) {
        mineStack.isHidden = !isMine
        theirsStack.isHidden = isMine
        let body = message.body ?? ""
        let timeText: String = {
            guard let createdAt = message.createdAt else { return "" }
            let date = Date(timeIntervalSince1970: TimeInterval(createdAt) / 1000.0)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "M月d日 H:mm"
            return formatter.string(from: date)
        }()
        if isMine {
            mineTextLabel.text = body
            mineTimeLabel.text = timeText
        } else {
            theirsTextLabel.text = body
            theirsTimeLabel.text = timeText
        }
    }
}
