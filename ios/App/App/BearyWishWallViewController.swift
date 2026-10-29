import UIKit

// ===== 功能许愿墙（2026-10-29 补缺第 21 项；进 100 包）=====
// 产品口径（Li 2026-10-29 定）：仅 Plus 会员可发起许愿（服务端校验，App 侧只隐藏
// 发起钮）；所有登录用户可赞成 / 反对，游客只看不能投；每人每条一票、可改投、
// 再点同票取消；列表按净赞成（赞成减反对）降序（服务端排好，App 不再重排）；
// 管理员可标记“已完成”。投票走即时反馈口径：点按瞬间改数与选中态，服务端回包
// 对齐，失败回滚 + 摇头 + toast + warning 震动（与 10-29 即时性总口径同款）。
// 界面：全屏 modal + fadeRise（同反馈页）；左上文字「关闭」15pt 墨字、标题 17；
// iPad 内容列 600 居中（顶栏与内容列同宽，P2-17 口径）；动效只走 transform /
// opacity，新行入场错峰、已有行不重播；无骨架屏（已删口径）；组件走 iOS 系统
// 组件，图标只用官方包（本页无主图标，状态 pill 纯文字）。
// 后端状态：本文件对应接口（GET /beary/api/wishes、POST /beary/api/wishes、
// POST /beary/api/wishes/:id/vote、POST /beary/api/wishes/:id/status）与 DDL
// 已备好在 worker.js（未部署）与 wish-wall-ddl.sql；后端未部署前接口 404，
// 本页走失败态（重试钮），不编造假数据。

// MARK: - 行视图（纯代码行：标题 / 详情 / 发起人时间 / 净赞成 / 两票钮 / 状态 pill）

private final class WishRowView: UIView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let metaLabel = UILabel()
    private let netLabel = UILabel()
    private let donePill = UILabel()
    private let upButton = BearyButton.make(style: .secondaryOutline(.compact), title: "赞成")
    private let downButton = BearyButton.make(style: .secondaryOutline(.compact), title: "反对")
    private let doneButton = BearyButton.make(style: .secondaryOutline(.compact), title: "标记已完成")
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onMarkDone: (() -> Void)?
    var isAdminRow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyColors.surface
        layer.cornerRadius = 16
        titleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        detailLabel.font = UIFont.systemFont(ofSize: 13)
        detailLabel.textColor = BearyColors.gray
        detailLabel.numberOfLines = 3
        metaLabel.font = UIFont.systemFont(ofSize: 12)
        metaLabel.textColor = BearyColors.gray
        netLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        netLabel.textColor = BearyColors.ink
        donePill.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        donePill.textColor = UIColor(red: 0.13, green: 0.55, blue: 0.22, alpha: 1)
        donePill.backgroundColor = UIColor(red: 0.13, green: 0.55, blue: 0.22, alpha: 0.12)
        donePill.layer.cornerRadius = 9
        donePill.clipsToBounds = true
        donePill.textAlignment = .center
        donePill.text = "已完成"
        upButton.addTarget(self, action: #selector(upTapped), for: .touchUpInside)
        downButton.addTarget(self, action: #selector(downTapped), for: .touchUpInside)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        let voteRow = UIStackView(arrangedSubviews: [upButton, downButton])
        voteRow.axis = .horizontal
        voteRow.spacing = 8
        // 15：标题与 donePill 放同一横向容器——pill 占 56 宽时标题只剩剩余宽换行，
        // 首行不再被右上角悬浮 pill 盖住；未完成时 pill 隐藏，stack 自动不占位，标题回满宽。
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        donePill.setContentHuggingPriority(.required, for: .horizontal)
        donePill.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, donePill])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .top
        let stack = UIStackView(arrangedSubviews: [titleRow, detailLabel, metaLabel, netLabel, voteRow, doneButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            donePill.widthAnchor.constraint(equalToConstant: 56),
            donePill.heightAnchor.constraint(equalToConstant: 18),
            upButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
            downButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
            doneButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func upTapped() { onUp?() }
    @objc private func downTapped() { onDown?() }
    @objc private func doneTapped() { onMarkDone?() }

    /// 只改文案与选中态，不重播入场动效（已有行更新口径）。
    func configure(item: BearyAPI.WishItem, isAdmin: Bool) {
        titleLabel.text = item.title ?? ""
        detailLabel.text = item.detail ?? ""
        detailLabel.isHidden = (item.detail ?? "").isEmpty
        let author = item.authorName ?? "beary 用户"
        let time = item.createdAt.map { BearyDiaryCardCell.feedTimeString(ms: $0) } ?? ""
        metaLabel.text = time.isEmpty ? author : "\(author) · \(time)"
        let up = item.upCount ?? 0
        let down = item.downCount ?? 0
        let net = up - down
        netLabel.text = "净赞成 \(net >= 0 ? "+" : "")\(net)"
        upButton.setTitle("赞成 \(up)", for: .normal)
        downButton.setTitle("反对 \(down)", for: .normal)
        setVoteSelected(upButton, selected: item.myVote == 1)
        setVoteSelected(downButton, selected: item.myVote == -1)
        let done = item.status == "done"
        donePill.isHidden = !done
        // 已完成即闭环：票钮置灰不可点（禁用态本身即不可用示意，不另弹 toast）。
        upButton.isEnabled = !done
        downButton.isEnabled = !done
        upButton.alpha = done ? 0.4 : 1
        downButton.alpha = done ? 0.4 : 1
        doneButton.isHidden = !(isAdmin && !done)
    }

    /// 投票选中态走按钮公共样式（BearyButton.applyVoteSelected）；本处只转发，不再各写一套颜色。
    private func setVoteSelected(_ button: BearyButton, selected: Bool) {
        button.applyVoteSelected(selected)
    }

    /// 拒绝摇头（transform 平移关键帧，不动布局；与即时性总口径的拒绝动效同款）。
    /// 22(a)：补减动效早退——与标准 playDenyShake 一致，减动效时只跳视觉抖动；
    /// 本处调用点（voteTapped 失败分支）已另给 warning 震动，shake 本身不补震动/音效。
    func shake() {
        if UIAccessibility.isReduceMotionEnabled { return }
        let anim = CAKeyframeAnimation(keyPath: "transform.translation.x")
        anim.values = [0, -8, 8, -5, 5, 0]
        anim.duration = 0.35
        layer.add(anim, forKey: "wish-row-shake")
    }
}

// MARK: - 列表页

final class BearyWishWallViewController: UIViewController {
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let createButton = BearyButton.make(style: .primaryPill(.ink), title: "发起许愿")
    private let emptyLabel = UILabel()
    private let failureLabel = UILabel()
    private let retryButton = BearyButton.retryPill()
    private var wishes: [BearyAPI.WishItem] = []
    private var rowViews: [Int: WishRowView] = [:]
    private var voteGeneration: [Int: Int] = [:] // 2026-10-29：每条许愿投票代次，旧回包丢弃用
    private var shownWishIds: Set<Int> = []
    private var isLoading = false
    /// 13：600 上限约束（宽 ≥821 才激活，开关在 viewDidLayoutSubviews；Feed 断点同款）。
    private var colCapConstraints: [NSLayoutConstraint] = []
    var onCreated: ((BearyAPI.WishItem) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let closeButton = BearyHit44Button(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "功能许愿墙"
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = BearyColors.ink
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 12
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)
        view.addSubview(topBar)
        view.addSubview(scrollView)
        // 13：Feed 断点模式——600 上限只在宽 ≥821 激活（开关在 viewDidLayoutSubviews），
        // ≤820 时走 == 屏宽-32 的 iPhone 式全宽（左右 16），不再被常驻 600 上限收窄。
        let topBarWidth = topBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        topBarWidth.priority = .defaultHigh
        let topBarCap = topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        let scrollWidth = scrollView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        scrollWidth.priority = .defaultHigh
        let scrollCap = scrollView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        colCapConstraints = [topBarCap, scrollCap]
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBarCap,
            topBarWidth,
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scrollCap,
            scrollWidth,
            scrollView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        createButton.addTarget(self, action: #selector(createTapped), for: .touchUpInside)
        createButton.isHidden = !isCurrentUserPlus()
        emptyLabel.font = UIFont.systemFont(ofSize: 14)
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = "还没有愿望，Plus 会员可以发起第一个"
        emptyLabel.isHidden = true
        failureLabel.font = UIFont.systemFont(ofSize: 14)
        failureLabel.textColor = BearyColors.gray
        failureLabel.textAlignment = .center
        failureLabel.text = "加载失败"
        failureLabel.isHidden = true
        retryButton.setTitle("重试", for: .normal)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.isHidden = true
        contentStack.addArrangedSubview(createButton)
        contentStack.addArrangedSubview(emptyLabel)
        contentStack.addArrangedSubview(failureLabel)
        contentStack.addArrangedSubview(retryButton)
        NSLayoutConstraint.activate([
            createButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.ink).height),
            retryButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.compact).height),
        ])
        loadWishes()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 13：Feed 同款断点开关——状态不变不开关，避免布局循环。
        let wantCap = view.bounds.width >= 821
        for cap in colCapConstraints where cap.isActive != wantCap {
            cap.isActive = wantCap
        }
    }

    @objc private func closeTapped() { dismiss(animated: BearyMotion.animated(true), completion: nil) }
    @objc private func retryTapped() { loadWishes() }

    /// App 侧 Plus 门：仅决定发起钮显隐，真正校验在服务端（plus_until > now 或永久阈值）。
    private func isCurrentUserPlus() -> Bool {
        guard let until = SessionManager.shared.currentUser?.plusUntil else { return false }
        let now = Int(Date().timeIntervalSince1970 * 1000)
        return until >= 4102444800000 || until > now
    }

    private var isAdmin: Bool { SessionManager.shared.currentUser?.isAdmin == true }
    private var isGuest: Bool { SessionManager.shared.isGuestMode }

    @objc private func createTapped() {
        let vc = BearyWishCreateViewController()
        vc.modalPresentationStyle = .fullScreen
        vc.transitioningDelegate = SceneDelegate.chrome?.fadeRiseTransitionDelegate
        vc.onCreated = { [weak self] wish in
            guard let self = self else { return }
            self.wishes.insert(wish, at: 0)
            self.renderWishes()
            BearyToast.show(in: self.view, message: "许愿已发布", aboveFAB: false)
            self.onCreated?(wish)
        }
        present(vc, animated: BearyMotion.animated(true), completion: nil)
    }

    private func loadWishes() {
        guard !isLoading else { return }
        isLoading = true
        failureLabel.isHidden = true
        retryButton.isHidden = true
        BearyAPI.shared.fetchWishes { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                case .success(let resp):
                    self.wishes = resp.wishes ?? []
                    self.renderWishes()
                case .failure:
                    self.failureLabel.isHidden = false
                    self.retryButton.isHidden = false
                }
            }
        }
    }

    /// 渲染：服务端顺序即净赞成降序，不重排；仅新 id 行入场错峰（transform/opacity），已有行只改文案不重播。
    private func renderWishes() {
        for (_, row) in rowViews { row.removeFromSuperview() }
        rowViews = [:]
        emptyLabel.isHidden = !wishes.isEmpty
        var newRows: [WishRowView] = []
        for item in wishes {
            guard let id = item.id else { continue }
            let row = WishRowView()
            row.configure(item: item, isAdmin: isAdmin)
            row.onUp = { [weak self] in self?.voteTapped(wishId: id, target: 1) }
            row.onDown = { [weak self] in self?.voteTapped(wishId: id, target: -1) }
            row.onMarkDone = { [weak self] in self?.markDoneTapped(wishId: id) }
            contentStack.addArrangedSubview(row)
            rowViews[id] = row
            if !shownWishIds.contains(id) {
                shownWishIds.insert(id)
                newRows.append(row)
            }
        }
        if !BearyMotion.animated(true) { return }
        for (index, row) in newRows.enumerated() {
            row.alpha = 0
            row.transform = CGAffineTransform(translationX: 0, y: 6)
            UIView.animate(withDuration: 0.25, delay: min(Double(index) * 0.05, 0.5), options: [.curveEaseOut], animations: {
                row.alpha = 1
                row.transform = .identity
            }, completion: nil)
        }
    }

    private func indexOfWish(_ id: Int) -> Int? { wishes.firstIndex { $0.id == id } }

    /// 投票：游客走登录页；登录用户点按瞬间改数与选中态，回包对齐，失败回滚 + 摇头 + toast。
    private func voteTapped(wishId: Int, target: Int) {
        if isGuest {
            presentLoginPage()
            return
        }
        guard let index = indexOfWish(wishId) else { return }
        let old = wishes[index]
        let newVote: Int? = (old.myVote == target) ? nil : target
        var next = old
        var up = old.upCount ?? 0
        var down = old.downCount ?? 0
        if old.myVote == 1 { up -= 1 }
        if old.myVote == -1 { down -= 1 }
        if newVote == 1 { up += 1 }
        if newVote == -1 { down += 1 }
        next.upCount = up
        next.downCount = down
        next.myVote = newVote
        wishes[index] = next
        rowViews[wishId]?.configure(item: next, isAdmin: isAdmin)
        BearySoundPlayer.play(.wishDing)
        // 2026-10-29 修：每条许愿投票代次——先发回包后到时直接丢弃，不得覆盖后一次的操作与失败回滚。
        voteGeneration[wishId, default: 0] += 1
        let gen = voteGeneration[wishId] ?? 0
        let sendVote = newVote ?? 0
        BearyAPI.shared.voteWish(id: wishId, vote: sendVote) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, let idx = self.indexOfWish(wishId), self.voteGeneration[wishId] == gen else { return }
                switch result {
                case .success(let resp):
                    var confirmed = self.wishes[idx]
                    confirmed.upCount = resp.up ?? confirmed.upCount
                    confirmed.downCount = resp.down ?? confirmed.downCount
                    confirmed.myVote = resp.myVote
                    self.wishes[idx] = confirmed
                    self.rowViews[wishId]?.configure(item: confirmed, isAdmin: self.isAdmin)
                case .failure:
                    self.wishes[idx] = old
                    self.rowViews[wishId]?.configure(item: old, isAdmin: self.isAdmin)
                    self.rowViews[wishId]?.shake()
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    BearyToast.show(in: self.view, message: "投票失败，请稍后再试", aboveFAB: false)
                }
            }
        }
    }

    private func markDoneTapped(wishId: Int) {
        guard let index = indexOfWish(wishId) else { return }
        let old = wishes[index]
        var next = old
        next.status = "done"
        wishes[index] = next
        rowViews[wishId]?.configure(item: next, isAdmin: isAdmin)
        BearyAPI.shared.markWishDone(id: wishId) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, let idx = self.indexOfWish(wishId) else { return }
                switch result {
                case .success:
                    BearyToast.show(in: self.view, message: "已标记完成", aboveFAB: false)
                case .failure:
                    self.wishes[idx] = old
                    self.rowViews[wishId]?.configure(item: old, isAdmin: self.isAdmin)
                    BearyToast.show(in: self.view, message: "标记失败，请稍后再试", aboveFAB: false)
                }
            }
        }
    }

    /// 游客投票走登录页（登录页全屏 modal；成功后刷新 /me 与列表，失败态不留残页）。
    private func presentLoginPage() {
        let login = BearyLoginViewController()
        login.modalPresentationStyle = .fullScreen
        login.onLoggedIn = { [weak self] in
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
            SessionManager.shared.refreshMe { _ in
                DispatchQueue.main.async {
                    self?.createButton.isHidden = !(self?.isCurrentUserPlus() ?? false)
                    self?.loadWishes()
                }
            }
        }
        login.onCancelled = { [weak self] in
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
        present(login, animated: BearyMotion.animated(true), completion: nil)
    }
}

// MARK: - 发起页（标题必填 + 详情可选两项；服务端再校验 Plus 与长度）

final class BearyWishCreateViewController: UIViewController, UITextViewDelegate {
    private let scrollView = UIScrollView()
    private let titleField = UITextField()
    private let detailView = UITextView()
    private let detailPlaceholder = UILabel()
    private let submitButton = BearyButton.make(style: .primaryPill(.ink), title: "发布许愿")
    /// 11：提交锁——锁期间 titleChanged 不得重新启用提交钮（服务端幂等另有工人做）。
    private var isSubmitting = false
    /// 13：600 上限约束（宽 ≥821 才激活，开关在 viewDidLayoutSubviews；与列表页同款）。
    private var colCapConstraints: [NSLayoutConstraint] = []
    /// 17：当前焦点框（键盘弹出时把它滚到可见区）。
    private weak var activeField: UIView?
    var onCreated: ((BearyAPI.WishItem) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        let closeButton = BearyHit44Button(type: .system)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(BearyColors.ink, for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "发起许愿"
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = BearyColors.ink
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.placeholder = "愿望标题"
        titleField.font = UIFont.systemFont(ofSize: 16)
        titleField.textColor = BearyColors.ink
        titleField.borderStyle = .roundedRect
        titleField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.font = UIFont.systemFont(ofSize: 15)
        detailView.textColor = BearyColors.ink
        detailView.layer.borderColor = BearyColors.ink.withAlphaComponent(0.2).cgColor
        detailView.layer.borderWidth = 1
        detailView.layer.cornerRadius = 12
        detailView.delegate = self
        detailPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        detailPlaceholder.text = "补充说明（可选）"
        detailPlaceholder.font = UIFont.systemFont(ofSize: 15)
        detailPlaceholder.textColor = BearyColors.gray
        detailView.addSubview(detailPlaceholder)
        submitButton.translatesAutoresizingMaskIntoConstraints = false
        submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
        submitButton.isEnabled = false
        submitButton.alpha = 0.4
        titleField.addTarget(self, action: #selector(titleFieldDidBegin), for: .editingDidBegin)
        titleField.addTarget(self, action: #selector(fieldDidEnd), for: .editingDidEnd)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        view.addSubview(scrollView)
        scrollView.addSubview(titleField)
        scrollView.addSubview(detailView)
        scrollView.addSubview(submitButton)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        // 13：发起页上限统一到 600（原字段/按钮 568），断点开关与列表页同款。
        let topBarWidth = topBar.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        topBarWidth.priority = .defaultHigh
        let topBarCap = topBar.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        colCapConstraints.append(topBarCap)
        // 17：表单入滚动容器，底部跟随 keyboardLayoutGuide（键盘弹出时滚动区收缩、
        // 内容可滚；键盘收起时 ≤ 安全区底约束兜底，不致伸到 Home 条下）。
        let scrollBottomToKeyboard = scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        scrollBottomToKeyboard.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            topBarCap,
            topBarWidth,
            topBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            topBar.heightAnchor.constraint(equalToConstant: 52),
            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            closeButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor),
            scrollBottomToKeyboard,
            titleField.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            titleField.heightAnchor.constraint(equalToConstant: 44),
            detailView.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 12),
            detailView.heightAnchor.constraint(equalToConstant: 160),
            detailPlaceholder.topAnchor.constraint(equalTo: detailView.topAnchor, constant: 8),
            detailPlaceholder.leadingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: 8),
            submitButton.topAnchor.constraint(equalTo: detailView.bottomAnchor, constant: 20),
            submitButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.ink).height),
            // 内容底含提交钮 +16 边距——键盘顶起后提交钮也可滚到可见区。
            submitButton.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
        ] + fieldColumnConstraints(for: titleField)
          + fieldColumnConstraints(for: detailView)
          + fieldColumnConstraints(for: submitButton))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 13：Feed 同款断点开关——状态不变不开关，避免布局循环。
        let wantCap = view.bounds.width >= 821
        for cap in colCapConstraints where cap.isActive != wantCap {
            cap.isActive = wantCap
        }
    }

    /// 13：表单字段居中列约束——宽 == 滚动容器 frame 宽-32（defaultHigh，≤820 全宽-32）
    /// + 600 上限（存入 colCapConstraints，≥821 才激活）+ 左右 ≥16 + 居中。
    private func fieldColumnConstraints(for field: UIView) -> [NSLayoutConstraint] {
        let fullWidth = field.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        fullWidth.priority = .defaultHigh
        let cap = field.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        colCapConstraints.append(cap)
        return [
            field.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            cap,
            fullWidth,
            field.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
        ]
    }

    @objc private func closeTapped() { dismiss(animated: BearyMotion.animated(true), completion: nil) }

    /// 11：提交钮启用态唯一入口——提交锁期间直接返回，标题变化不得重新启用提交钮。
    @objc private func titleChanged() {
        guard !isSubmitting else { return }
        let ok = !(titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        submitButton.isEnabled = ok
        submitButton.alpha = ok ? 1 : 0.4
    }

    func textViewDidChange(_ textView: UITextView) {
        detailPlaceholder.isHidden = !textView.text.isEmpty
    }

    @objc private func titleFieldDidBegin() { activeField = titleField }
    @objc private func fieldDidEnd() { activeField = nil }

    func textViewDidBeginEditing(_ textView: UITextView) { activeField = textView }
    func textViewDidEndEditing(_ textView: UITextView) { activeField = nil }

    /// 17：键盘弹出/变框后（keyboardLayoutGuide 已收缩滚动区），下一 runloop 待布局
    /// 完成后再把焦点框滚到可见区，避免按旧 bounds 算错；减动效时瞬时落位。
    @objc private func keyboardWillShow() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let field = self.activeField else { return }
            self.view.layoutIfNeeded()
            let rect = field.convert(field.bounds, to: self.scrollView)
            self.scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -8), animated: BearyMotion.animated(true))
        }
    }

    @objc private func submitTapped() {
        guard !isSubmitting else { return }
        let title = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let detail = detailView.text ?? ""
        isSubmitting = true
        submitButton.isEnabled = false
        submitButton.alpha = 0.4
        BearyAPI.shared.createWish(title: title, detail: detail) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let wish):
                    self.onCreated?(wish)
                    self.dismiss(animated: BearyMotion.animated(true), completion: nil)
                case .failure(let err):
                    // 11：解锁后按当前标题重新评估启用态，不再无条件 isEnabled = true
                    //（提交期间标题被清空时，失败后提交钮仍应保持禁用）。
                    self.isSubmitting = false
                    self.titleChanged()
                    let message: String
                    if case .server(let code) = err, code == "not_plus" {
                        message = "仅 Plus 会员可发起许愿"
                    } else if case .server(let code) = err, code == "rate_limited" {
                        message = "操作太频繁，请稍后再试"
                    } else {
                        message = "发布失败，请稍后再试"
                    }
                    BearyToast.show(in: self.view, message: message, aboveFAB: false)
                }
            }
        }
    }
}
