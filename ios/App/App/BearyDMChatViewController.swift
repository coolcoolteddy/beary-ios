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
    // 审计：发送钮视觉高 32 不变，热区用 Hit44 扩到 44（读“全部已读”钮同款口径）。
    private let sendButton = BearyHit44Button(type: .system)
    private let newMessagePill = UIButton(type: .system)
    private let placeholderLabel = UILabel()
    private let countLabel = UILabel()
    private var inputBarBottomConstraint: NSLayoutConstraint?
    private var messages: [BearyAPI.DMMessage] = []
    // 审计：下拉刷新与翻旧消息共用同一 busy 锁，不再两套守卫并发。
    private var messageBusy = false
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
        // 审计：输入框占位（空输入时显，见 updateInputChrome）。
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = BearyColors.gray
        placeholderLabel.text = "输入消息"
        inputTextView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.topAnchor.constraint(equalTo: inputTextView.topAnchor, constant: 8),
            placeholderLabel.leadingAnchor.constraint(equalTo: inputTextView.leadingAnchor, constant: 15),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: inputTextView.trailingAnchor, constant: -10),
        ])
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
        // 审计：接近 2000 字实时计数（仅 ≥1800 字出现）与“新消息”pill。
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 11))
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = BearyColors.gray
        countLabel.isHidden = true
        view.addSubview(countLabel)
        newMessagePill.translatesAutoresizingMaskIntoConstraints = false
        newMessagePill.setTitle("新消息", for: .normal)
        newMessagePill.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        newMessagePill.titleLabel?.adjustsFontForContentSizeCategory = true
        newMessagePill.setTitleColor(BearyColors.bg, for: .normal)
        newMessagePill.backgroundColor = BearyColors.ink
        newMessagePill.layer.cornerRadius = 16
        newMessagePill.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        newMessagePill.isHidden = true
        newMessagePill.addTarget(self, action: #selector(newMessagePillTapped), for: .touchUpInside)
        newMessagePill.bearyAddPressFeedback()
        view.addSubview(newMessagePill)
        NSLayoutConstraint.activate([
            countLabel.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -4),
            countLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            newMessagePill.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -8),
            newMessagePill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            newMessagePill.heightAnchor.constraint(equalToConstant: 32),
        ])

        inputBarBottomConstraint = inputBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        inputBarBottomConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            closeButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            // 审计：居中标题加左右限位，小屏＋大字体时不与关闭钮重叠（超长截断）。
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: closeButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
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
            // 审计：输入框补最大高度（约 5 行）；isScrollEnabled 已开，触顶后框内滚动。
            inputTextView.heightAnchor.constraint(lessThanOrEqualToConstant: 160),
            sendButton.leadingAnchor.constraint(equalTo: inputTextView.trailingAnchor, constant: 8),
            sendButton.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor, constant: -16),
            sendButton.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -9),
            sendButton.heightAnchor.constraint(equalToConstant: 32),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        loadLatest()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 审计复核结论：旧写法无条件触发。DM 全屏 modal 上再盖登录门时
        //（发送 401 → onRequireLogin → presentLoginGate）也会走 viewDidDisappear，
        // 旧写法会在仍在会话内时误刷新会话列表/通知。故只在真正 dismiss/出栈时触发。
        if isBeingDismissed || isMovingFromParent || presentingViewController == nil {
            // modal dismiss 后容器刷新会话列表未读与通知未读（本页不直接碰别页模型）。
            onClosed?()
        }
    }

    @objc private func closeTapped() {
        onBack?()
    }

    @objc private func refreshPulled() {
        loadLatest()
    }

    @objc private func keyboardWillShow(_ note: Notification) {
        applyKeyboard(note)
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        applyKeyboard(note)
    }

    @objc private func keyboardWillHide(_ note: Notification) {
        applyKeyboard(note)
    }

    /// 键盘跟随（审计）：跟系统时长曲线做动画；帧先 convert 到本视图坐标，
    /// 再按与视图底边的实际遮挡算 inset——iPad 浮动键盘、分屏不贴底时不按全高垫。
    /// 不抢滚动位：输入条顶起后表高缩小，旧 offset 自然保留，正在翻旧消息
    /// 的用户不被拽到底；新消息发送成功后由 loadLatest 的 wasAtBottom 分支处理。
    /// （iPad/分屏复核：旧代码直接取键盘帧高度、无 convert、无动画跟随，
    /// 缺陷在代码层面已证实；浮动/分屏键盘的实际遮挡仍待真机复验。）
    private func applyKeyboard(_ note: Notification) {
        guard let frameValue = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frameInView = view.convert(frameValue.cgRectValue, from: nil)
        let overlap = max(0, view.bounds.height - frameInView.minY - view.safeAreaInsets.bottom)
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curve = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue ?? 0
        let options = UIView.AnimationOptions(rawValue: UInt(curve << 16))
        inputBarBottomConstraint?.constant = -overlap
        UIView.animate(withDuration: duration, delay: 0, options: options, animations: {
            self.view.layoutIfNeeded()
        }, completion: nil)
    }

    func textViewDidChange(_ textView: UITextView) {
        updateSendButton()
        updateInputChrome()
    }

    /// 输入框占位与接近 2000 字计数（审计）：占位随有无文字显隐；
    /// 计数仅在 ≥1800 字时出现；发送时超限仍 toast（旧口径不动）。
    private func updateInputChrome() {
        placeholderLabel.isHidden = !inputTextView.text.isEmpty
        let count = inputTextView.text.count
        countLabel.isHidden = count < 1800
        countLabel.text = "\(count)/2000"
    }

    private func isNearBottom() -> Bool {
        guard !messages.isEmpty else { return true }
        let offsetY = tableView.contentOffset.y + tableView.bounds.height
        return offsetY >= tableView.contentSize.height - 80
    }

    @objc private func newMessagePillTapped() {
        newMessagePill.isHidden = true
        scrollToBottomIfNeeded()
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
        // 审计：已读失败不再“本页永不重试”——失败时不置 didMarkRead，
        // 下次 loadLatest 成功时再试，并 toast 说明（重试入口即下拉刷新）。
        BearyAPI.shared.markDMRead(userId: userId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success:
                    self.didMarkRead = true
                case .failure:
                    BearyToast.show(in: self.view, message: "未读标记失败，下拉刷新可重试")
                }
            }
        }
    }

    /// 最新页：服务端按 id 倒序下发，展示时反转为正序；成功后清未读。
    /// onLoaded 报告拉取开始时用户是否在底部附近（发送成功后的 pill 判定用）。
    private func loadLatest(onLoaded: ((Bool) -> Void)? = nil) {
        guard let userId = peer.id else { return }
        guard SessionManager.shared.isLoggedIn else {
            tableView.refreshControl?.endRefreshing()
            onRequireLogin?()
            return
        }
        guard !messageBusy else {
            tableView.refreshControl?.endRefreshing()
            return
        }
        messageBusy = true
        loadFailed = false
        let wasAtBottom = isNearBottom()
        BearyAPI.shared.fetchDMHistory(userId: userId, limit: 30) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.messageBusy = false
                self.tableView.refreshControl?.endRefreshing()
                switch result {
                case .success(let history):
                    let fetched = history.resolvedMessages.reversed()
                    self.messages = Array(fetched)
                    self.hasMoreOlder = history.resolvedMessages.count >= 30
                    self.loadFailed = false
                    self.updateEmptyState()
                    self.tableView.reloadData()
                    if wasAtBottom {
                        self.scrollToBottomIfNeeded()
                        self.newMessagePill.isHidden = true
                    }
                    self.markReadIfNeeded()
                    onLoaded?(wasAtBottom)
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

    /// 向上翻 older：before_id 取最旧一条 id；前插后以翻页前首条消息 id 为锚点
    /// 修正 offset（锚点行在视口内的相对位置不变），行高重算也不跳视口；
    /// 锚点丢失时才回落到整表高度差口径。
    private func loadOlder() {
        guard let userId = peer.id, !messageBusy, hasMoreOlder,
              let oldestId = messages.first?.id else { return }
        messageBusy = true
        let anchorId = oldestId
        let anchorViewportOffset: CGFloat = {
            let rect = tableView.rectForRow(at: IndexPath(row: 0, section: 0))
            return rect.origin.y - tableView.contentOffset.y
        }()
        let oldHeight = tableView.contentSize.height
        let oldOffsetY = tableView.contentOffset.y
        BearyAPI.shared.fetchDMHistory(userId: userId, beforeId: oldestId, limit: 30) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.messageBusy = false
                switch result {
                case .success(let history):
                    let older = Array(history.resolvedMessages.reversed())
                    self.hasMoreOlder = history.resolvedMessages.count >= 30
                    self.messages.insert(contentsOf: older, at: 0)
                    self.tableView.reloadData()
                    self.tableView.layoutIfNeeded()
                    if let anchorIndex = self.messages.firstIndex(where: { $0.id == anchorId }) {
                        let rect = self.tableView.rectForRow(at: IndexPath(row: anchorIndex, section: 0))
                        self.tableView.contentOffset = CGPoint(x: 0, y: rect.origin.y - anchorViewportOffset)
                    } else {
                        let delta = self.tableView.contentSize.height - oldHeight
                        self.tableView.contentOffset = CGPoint(x: 0, y: oldOffsetY + delta)
                    }
                case .failure:
                    // 审计：翻旧失败不再静默——toast 说明，hasMoreOlder 保持，
                    // 用户再次滚动到顶部即重试（loadOlder 守卫已放行）。
                    BearyToast.show(in: self.view, message: "加载更早消息失败，滚动可重试")
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
                    self.updateInputChrome()
                    // 服务端确认后重拉最新页再落行，不做乐观假态。
                    // 审计：发送成功不再强行拽到底部——仅用户已在底部附近时跟随，
                    // 否则显“新消息”pill，点按再到底部。
                    self.loadLatest { [weak self] wasAtBottom in
                        if !wasAtBottom { self?.newMessagePill.isHidden = false }
                    }
                case .failure(let error):
                    if case .unauthorized = error {
                        self.onRequireLogin?()
                    } else if case .http(403, _) = error {
                        self.sessionClosed = true
                        self.inputTextView.isEditable = false
                        self.updateSendButton()
                        self.updateEmptyState()
                        // 审计：403 即已关闭态，不再给自相矛盾的“请重试”。
                        BearyToast.show(in: self.view, message: "该会话已关闭")
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
        // 回到底部附近即收起“新消息”pill（程序化跟随到底同样收起）。
        if isNearBottom() {
            newMessagePill.isHidden = true
        }
        // 仅用户手势滚动到顶部附近且还有 older 时翻页：程序化滚动（首拉后
        // 回到底部、reloadData 布局抖动）不得触发，否则首屏会连翻 older。
        // 下拉刷新控件也在顶部，阈值取 120，与下拉手势不打架（下拉刷新在途
        // 时 loadOlder 的共用 busy 锁互斥）。
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
            textLabel.textColor = isMine ? BearyColors.onBrand : BearyColors.ink
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
