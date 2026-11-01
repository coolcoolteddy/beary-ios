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
// POST /beary/api/wishes/:id/vote、POST /beary/api/wishes/:id/status）已于
// 2026-10-29 部署上线；接口失败时本页走失败态（重试钮），不编造假数据。

// MARK: - 行视图（纯代码行：标题 / 详情 / 发起人时间 / 净赞成 / 两票钮 / 状态 pill）

private final class WishRowView: UIView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let metaLabel = UILabel()
    private let netLabel = UILabel()
    private let donePill = UILabel()
    private let expandButton = UIButton(type: .system)
    private var isDetailExpanded = false
    private var detailFullText = ""
    private var detailOverflow = false
    private let upButton = BearyButton.make(style: .secondaryOutline(.compact), title: "赞成")
    private let downButton = BearyButton.make(style: .secondaryOutline(.compact), title: "反对")
    /// 109：本行投票在途标志——configure 的禁用口径（已完成置灰）与它取并集，
    /// 在途结束由控制器 setVoting(false) 或下一次 configure 恢复，不另改文案与选中态。
    private var isVoting = false
    private var isDoneRow = false

    /// 109：在途锁的视觉侧——在途时两票钮禁用+置灰（点按不再进 voteTapped），
    /// 解锁后恢复（已完成行仍由 configure 的 done 口径保持禁用）。
    func setVoting(_ voting: Bool) {
        isVoting = voting
        upButton.isEnabled = !isDoneRow && !voting
        downButton.isEnabled = !isDoneRow && !voting
        upButton.alpha = (isDoneRow || voting) ? 0.4 : 1
        downButton.alpha = (isDoneRow || voting) ? 0.4 : 1
    }
    private let doneButton = BearyButton.make(style: .secondaryOutline(.compact), title: "标记已完成")
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?
    var onMarkDone: (() -> Void)?
    var isAdminRow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = BearyColors.surface
        layer.cornerRadius = 16
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.numberOfLines = 0
        detailLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = BearyColors.gray
        detailLabel.numberOfLines = 3
        metaLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.textColor = BearyColors.gray
        metaLabel.numberOfLines = 0
        // 15：净赞成缩为操作行末尾的辅助文字——弱化为 12 灰字（与作者时间弱信息行同档），
        // 不再独占一行；文案本身（“净赞成 ±N”）不变，见 configure。
        netLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
        netLabel.adjustsFontForContentSizeCategory = true
        netLabel.textColor = BearyColors.gray
        // 28：donePill 文字与底色均走动态色（文字 BearyColors.green，底色经
        // BearyColors.alpha 重解，不再硬编码绿值与 alpha 底）；公开 pill 橙色
        // 不在本文件，绝不动。固定 56×18 容器配 cappedFont 上限 14（31），
        // 14pt 行高约 17pt 不撑破 18pt 高，3 字在 56 宽内不截断。
        donePill.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 12, weight: .semibold), maximumPointSize: 14)
        donePill.adjustsFontForContentSizeCategory = true
        donePill.textColor = BearyColors.green
        donePill.backgroundColor = BearyColors.alpha(BearyColors.green, 0.12)
        donePill.layer.cornerRadius = 9
        donePill.clipsToBounds = true
        donePill.textAlignment = .center
        donePill.text = "已完成"
        upButton.addTarget(self, action: #selector(upTapped), for: .touchUpInside)
        downButton.addTarget(self, action: #selector(downTapped), for: .touchUpInside)
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        // P1-17：展开钮与完成钮补通用按压反馈；两票钮不补——投票已有即时选中
        // 反馈（configure 立改选中态）＋ wishDing 音效，再挂按压缩放/震动即重复反馈。
        // 29：详情展开钮——超三行时才出现，点按原位展开/收起，不新增二级页面；
        // 未超三行时隐藏（见 layoutSubviews 的 updateExpandVisibility）。
        expandButton.setTitle("展开", for: .normal)
        expandButton.setTitleColor(BearyColors.blue, for: .normal)
        expandButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        expandButton.titleLabel?.adjustsFontForContentSizeCategory = true
        expandButton.contentHorizontalAlignment = .leading
        expandButton.isHidden = true
        expandButton.addTarget(self, action: #selector(expandTapped), for: .touchUpInside)
        expandButton.bearyAddPressFeedback()
        doneButton.bearyAddPressFeedback()
        // 15：净赞成进操作行末尾——弹性 spacer 把它顶到行末，赞成/反对钮本身不动；
        // spacer 抗拉伸与抗压缩均最低，窄屏先压 spacer，不挤按钮与净赞成文案。
        let voteSpacer = UIView()
        voteSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        voteSpacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        let voteRow = UIStackView(arrangedSubviews: [upButton, downButton, voteSpacer, netLabel])
        voteRow.axis = .horizontal
        voteRow.spacing = 8
        voteRow.alignment = .center
        // 15：标题与 donePill 放同一横向容器——pill 占 56 宽时标题只剩剩余宽换行，
        // 首行不再被右上角悬浮 pill 盖住；未完成时 pill 隐藏，stack 自动不占位，标题回满宽。
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        donePill.setContentHuggingPriority(.required, for: .horizontal)
        donePill.setContentCompressionResistancePriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, donePill])
        titleRow.axis = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .top
        // 15：竖向栈减一层——netLabel 已随 voteRow 进操作行，不再单列；作者时间
        // metaLabel 仍为单独弱信息行，标题与 donePill 的同容器（titleRow）原样不动。
        let stack = UIStackView(arrangedSubviews: [titleRow, detailLabel, expandButton, metaLabel, voteRow, doneButton])
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

    @objc private func expandTapped() {
        // P2-10：高度一次落终值（不做高度插值动画），视觉衔接走内容淡入/transform；
        // 收起时恢复滚动偏移，使标题停在原位（内容缩短导致 scrollView 钳制偏移时
        // 标题本会被顶移，恢复后标题位置不变）。减动效时全部瞬时落位。
        isDetailExpanded.toggle()
        let expanding = isDetailExpanded
        var enclosingScroll: UIScrollView?
        var current: UIView? = superview
        while let view = current {
            if let scroll = view as? UIScrollView { enclosingScroll = scroll; break }
            current = view.superview
        }
        let oldOffset = enclosingScroll?.contentOffset
        detailLabel.layer.removeAllAnimations()
        updateExpandVisibility()
        // 高度一次落终值：先强制布局到最终态，再起内容动效，不让高度慢慢长出来。
        // 须连同滚动容器一起布局，否则 contentSize 未刷新、后一步的偏移钳制读到旧值。
        if let scroll = enclosingScroll { scroll.layoutIfNeeded() } else { superview?.layoutIfNeeded() }
        if let scroll = enclosingScroll, let old = oldOffset {
            let minY = -scroll.contentInset.top
            let maxY = max(scroll.contentSize.height - scroll.bounds.height + scroll.contentInset.bottom, minY)
            scroll.contentOffset = CGPoint(x: old.x, y: min(max(old.y, minY), maxY))
        }
        guard expanding, BearyMotion.animated(true) else {
            detailLabel.alpha = 1
            detailLabel.transform = .identity
            return
        }
        detailLabel.alpha = 0
        detailLabel.transform = CGAffineTransform(translationX: 0, y: 4)
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut], animations: {
            self.detailLabel.alpha = 1
            self.detailLabel.transform = .identity
        }, completion: nil)
    }

    /// 29：布局落定后量详情是否超三行——行宽取行宽减左右 16 内边距（label 帧未稳时
    /// 亦可用），超三行才显展开钮；展开态行数 0、文案“收起”，收起态行数 3、文案“展开”。
    /// 仅在取值变化时改属性，避免 layoutSubviews 内改布局引发循环。
    override func layoutSubviews() {
        super.layoutSubviews()
        updateExpandVisibility()
    }

    private func updateExpandVisibility() {
        guard !detailLabel.isHidden, !detailFullText.isEmpty else {
            if !expandButton.isHidden { expandButton.isHidden = true }
            return
        }
        if isDetailExpanded {
            if detailLabel.numberOfLines != 0 { detailLabel.numberOfLines = 0 }
            if expandButton.isHidden { expandButton.isHidden = false }
            if expandButton.title(for: .normal) != "收起" { expandButton.setTitle("收起", for: .normal) }
            detailOverflow = true
            return
        }
        let availWidth = bounds.width - 32
        guard availWidth > 0, let font = detailLabel.font else { return }
        let rect = (detailFullText as NSString).boundingRect(
            with: CGSize(width: availWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        let lines = Int(ceil(rect.height / max(font.lineHeight, 1)))
        let overflow = lines > 3
        if overflow != detailOverflow { detailOverflow = overflow }
        if detailLabel.numberOfLines != 3 { detailLabel.numberOfLines = 3 }
        if expandButton.isHidden != !overflow { expandButton.isHidden = !overflow }
        if overflow, expandButton.title(for: .normal) != "展开" { expandButton.setTitle("展开", for: .normal) }
    }

    /// 只改文案与选中态，不重播入场动效（已有行更新口径）。
    func configure(item: BearyAPI.WishItem, isAdmin: Bool) {
        titleLabel.text = item.title ?? ""
        // 29：详情文本变化时展开态复位（投票等仅改文案的 configure 不重置展开态）。
        let newDetail = item.detail ?? ""
        if newDetail != detailFullText {
            detailFullText = newDetail
            isDetailExpanded = false
            detailOverflow = false
            expandButton.isHidden = true
            // P2-10：文本换了，展开淡入动效的残态（alpha/位移）一并清掉，不留半透明行。
            detailLabel.layer.removeAllAnimations()
            detailLabel.alpha = 1
            detailLabel.transform = .identity
        }
        detailLabel.text = newDetail
        detailLabel.isHidden = newDetail.isEmpty
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
        isDoneRow = done
        donePill.isHidden = !done
        // 已完成即闭环：票钮置灰不可点（禁用态本身即不可用示意，不另弹 toast）。
        // 109：与在途标志取并集——在途行 configure 不得把票钮提前解开。
        upButton.isEnabled = !done && !isVoting
        downButton.isEnabled = !done && !isVoting
        upButton.alpha = (done || isVoting) ? 0.4 : 1
        downButton.alpha = (done || isVoting) ? 0.4 : 1
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
    // P2-18：加载/失败态迁入已有 BearyStateView（不新建组件）；空态仍走原
    // emptyLabel，不强迫空态套同一插图——故 stateView 两态均不传 iconName。
    private let wishStateView = BearyStateView()
    private var wishes: [BearyAPI.WishItem] = []
    private var rowViews: [Int: WishRowView] = [:]
    private var voteGeneration: [Int: Int] = [:] // 2026-10-29：每条许愿投票代次，旧回包丢弃用
    /// 109：每条许愿投票在途锁——代次只拦过期回包、不拦多发；本集合拦多发：
    /// 在途点按直接忽略（票钮同时禁用+置灰），回包/失败后解锁，不改代次与排序逻辑。
    private var votingWishIds: Set<Int> = []
    private var isLoading = false
    /// 13：600 上限约束（宽 ≥821 才激活，开关在 viewDidLayoutSubviews；Feed 断点同款）。
    private var colCapConstraints: [NSLayoutConstraint] = []
    /// 116 子页空白守卫（同 BearySettingsSubpages.swift 守卫说明）。
    private let subpageLayoutGuard = BearySubpageLayoutGuard()
    private var topBarView: UIView?
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
        // 31：固定 52 高顶栏配 cappedFont（关闭 15、标题 17，上限 20，不撑破顶栏）。
        closeButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 15))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "功能许愿墙"
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
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
        topBarView = topBar
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
        emptyLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.textColor = BearyColors.gray
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.text = "还没有愿望，Plus 会员可以发起第一个"
        emptyLabel.isHidden = true
        // P2-18：加载/失败两态的文案与重试动作与旧口径一致（“加载中…”/“加载失败”/“重试”），
        // 仅承载体换成 BearyStateView；空态仍走 emptyLabel，不进本视图。
        wishStateView.translatesAutoresizingMaskIntoConstraints = false
        wishStateView.isHidden = true
        contentStack.addArrangedSubview(createButton)
        contentStack.addArrangedSubview(wishStateView)
        contentStack.addArrangedSubview(emptyLabel)
        NSLayoutConstraint.activate([
            createButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.ink).height),
        ])
        loadWishes()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subpageLayoutGuard.resetForAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 13：Feed 同款断点开关——状态不变不开关，避免布局循环。
        let wantCap = view.bounds.width >= 821
        for cap in colCapConstraints where cap.isActive != wantCap {
            cap.isActive = wantCap
        }
        // 116 子页空白守卫（同 BearySettingsSubpages.swift 守卫说明）。
        subpageLayoutGuard.applyIfNeeded(page: "功能许愿墙", view: view, topView: topBarView)
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
            BearyToast.show(in: self.view, message: "许愿已发布")
            self.onCreated?(wish)
        }
        present(vc, animated: BearyMotion.animated(true), completion: nil)
    }

    /// 116 数据填入动效：状态视图由隐藏变可见时只淡入本身（alpha
    /// 0→1、0.25s，不动 transform／布局）；已可见时不重播；减动效或
    /// 未进窗口时直设终值。成功时状态视图直接隐藏、行走已有错峰。
    private func showStateViewFaded() {
        let wasHidden = wishStateView.isHidden
        wishStateView.isHidden = false
        guard wasHidden, !UIAccessibility.isReduceMotionEnabled, wishStateView.window != nil else {
            wishStateView.alpha = 1
            return
        }
        wishStateView.alpha = 0
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.wishStateView.alpha = 1
        })
    }

    private func loadWishes() {
        guard !isLoading else { return }
        isLoading = true
        // P2-18：加载态走 BearyStateView（转圈 + “加载中…”）；成功/失败回包时统一收起。
        wishStateView.configure(kind: .loading, title: "加载中…", subtitle: nil, iconName: nil, actionTitle: nil)
        showStateViewFaded()
        BearyAPI.shared.fetchWishes { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                switch result {
                case .success(let resp):
                    self.wishStateView.isHidden = true
                    self.wishes = resp.wishes ?? []
                    self.renderWishes()
                case .failure:
                    // P2-18：失败态走 BearyStateView（“加载失败”+“重试”，动作复用 retryTapped）。
                    self.wishStateView.configure(kind: .error, title: "加载失败", subtitle: nil, iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.retryTapped() })
                    self.showStateViewFaded()
                }
            }
        }
    }

    /// P0-9：按 wish ID 复用行——已有行只 configure 改文案，不重建、不重播入场动效；
    /// 展开态存在行视图自身，复用即保留（仅详情文本变化时 configure 内部复位）；
    /// 仅新增 ID 建行并入场错峰；消失 ID 摘除；顺序变化时同批行先摘后按服务端
    /// 顺序重挂（视图对象不变，展开态与按压态不丢）。服务端顺序即净赞成降序，不重排。
    private func renderWishes() {
        let oldRows = rowViews
        emptyLabel.isHidden = !wishes.isEmpty
        var newRows: [WishRowView] = []
        var orderedRows: [WishRowView] = []
        for item in wishes {
            guard let id = item.id else { continue }
            if let row = oldRows[id] {
                row.configure(item: item, isAdmin: isAdmin)
                orderedRows.append(row)
            } else {
                let row = WishRowView()
                row.configure(item: item, isAdmin: isAdmin)
                row.onUp = { [weak self] in self?.voteTapped(wishId: id, target: 1) }
                row.onDown = { [weak self] in self?.voteTapped(wishId: id, target: -1) }
                row.onMarkDone = { [weak self] in self?.markDoneTapped(wishId: id) }
                rowViews[id] = row
                orderedRows.append(row)
                newRows.append(row)
            }
        }
        let liveIds = Set(wishes.compactMap { $0.id })
        for (id, row) in oldRows where !liveIds.contains(id) {
            row.removeFromSuperview()
            rowViews.removeValue(forKey: id)
        }
        // 先摘后重挂：栈内固定位（发起钮/stateView/空态）在前，行按服务端顺序跟后；
        // 摘除只脱离栈布局，不销毁视图，故复用行的展开态保留。
        for row in orderedRows { row.removeFromSuperview() }
        for row in orderedRows { contentStack.addArrangedSubview(row) }
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
        // 109：在途锁——本条已有投票请求在途时点按直接忽略，不多发请求；
        // 锁在回包闭包首行无条件解除（在代次守卫之前），过期回包也不留死锁。
        guard !votingWishIds.contains(wishId) else { return }
        votingWishIds.insert(wishId)
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
        rowViews[wishId]?.setVoting(true)
        BearySoundPlayer.play(.wishDing)
        // 2026-10-29 修：每条许愿投票代次——先发回包后到时直接丢弃，不得覆盖后一次的操作与失败回滚。
        voteGeneration[wishId, default: 0] += 1
        let gen = voteGeneration[wishId] ?? 0
        let sendVote = newVote ?? 0
        BearyAPI.shared.voteWish(id: wishId, vote: sendVote) { [weak self] result in
            DispatchQueue.main.async {
                // 109：先解锁再判代次——成功/失败/过期回包一律解锁，不留死锁；
                // 代次逻辑原样不动，仍由下一行守卫丢弃过期回包。
                self?.votingWishIds.remove(wishId)
                self?.rowViews[wishId]?.setVoting(false)
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
                    BearyToast.show(in: self.view, message: "投票失败，请稍后再试")
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
                    BearyToast.show(in: self.view, message: "已标记完成")
                case .failure:
                    self.wishes[idx] = old
                    self.rowViews[wishId]?.configure(item: old, isAdmin: self.isAdmin)
                    BearyToast.show(in: self.view, message: "标记失败，请稍后再试")
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
    // 30：长度提示（服务端：标题 1–100、详情 ≤2000）与字段级错误行。
    private let titleCountLabel = UILabel()
    private let detailCountLabel = UILabel()
    private let fieldErrorLabel = UILabel()
    /// 字段级错误行隐藏时压为 0 高（非栈容器里 hidden 仍占约束位，需显式压高才不留空隙）。
    private var fieldErrorHeight: NSLayoutConstraint?
    private static let titleLimit = 100
    private static let detailLimit = 2000
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
        // 31：固定 52 高顶栏配 cappedFont（与列表页同款）。
        closeButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 15))
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = true
        closeButton.accessibilityLabel = "关闭"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.bearyAddPressFeedback()
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "发起许愿"
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.placeholder = "愿望标题"
        // 31：44 高单行框配 cappedFont（上限 20，行高不撑破 44 高）；详情框可滚动，
        // 故走 scaledFont（反馈页 160 框同款），超大字号下框内滚动而非截断。
        titleField.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16))
        titleField.adjustsFontForContentSizeCategory = true
        titleField.textColor = BearyColors.ink
        titleField.borderStyle = .roundedRect
        titleField.addTarget(self, action: #selector(titleChanged), for: .editingChanged)
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailView.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        detailView.adjustsFontForContentSizeCategory = true
        detailView.textColor = BearyColors.ink
        detailView.layer.bearyDynamicBorderColor = BearyColors.ink.withAlphaComponent(0.2)
        detailView.layer.borderWidth = 1
        detailView.layer.cornerRadius = 12
        detailView.delegate = self
        detailPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        detailPlaceholder.text = "补充说明（可选）"
        detailPlaceholder.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 15))
        detailPlaceholder.adjustsFontForContentSizeCategory = true
        detailPlaceholder.textColor = BearyColors.gray
        detailView.addSubview(detailPlaceholder)
        // 30：计数行右对齐、超限变红；字段级错误行默认隐藏，见 submitTapped 的 bad wish 分支。
        for label in [titleCountLabel, detailCountLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12))
            label.adjustsFontForContentSizeCategory = true
            label.textColor = BearyColors.gray
            label.textAlignment = .right
        }
        titleCountLabel.text = "0/100"
        detailCountLabel.text = "0/2000"
        fieldErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldErrorLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        fieldErrorLabel.adjustsFontForContentSizeCategory = true
        fieldErrorLabel.textColor = BearyColors.red
        fieldErrorLabel.numberOfLines = 0
        fieldErrorLabel.text = "标题需为 1–100 字，详情最多 2000 字，请检查后重试"
        fieldErrorLabel.isHidden = true
        fieldErrorHeight = fieldErrorLabel.heightAnchor.constraint(equalToConstant: 0)
        fieldErrorHeight?.isActive = true
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
        scrollView.addSubview(titleCountLabel)
        scrollView.addSubview(detailView)
        scrollView.addSubview(detailCountLabel)
        scrollView.addSubview(fieldErrorLabel)
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
            titleCountLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            detailView.topAnchor.constraint(equalTo: titleCountLabel.bottomAnchor, constant: 8),
            detailView.heightAnchor.constraint(equalToConstant: 160),
            detailPlaceholder.topAnchor.constraint(equalTo: detailView.topAnchor, constant: 8),
            detailPlaceholder.leadingAnchor.constraint(equalTo: detailView.leadingAnchor, constant: 8),
            detailCountLabel.topAnchor.constraint(equalTo: detailView.bottomAnchor, constant: 4),
            fieldErrorLabel.topAnchor.constraint(equalTo: detailCountLabel.bottomAnchor, constant: 8),
            submitButton.topAnchor.constraint(equalTo: fieldErrorLabel.bottomAnchor, constant: 12),
            submitButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.primaryPill(.ink).height),
            // 内容底含提交钮 +16 边距——键盘顶起后提交钮也可滚到可见区。
            submitButton.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
        ] + fieldColumnConstraints(for: titleField)
          + fieldColumnConstraints(for: titleCountLabel)
          + fieldColumnConstraints(for: detailView)
          + fieldColumnConstraints(for: detailCountLabel)
          + fieldColumnConstraints(for: fieldErrorLabel)
          + fieldColumnConstraints(for: submitButton))
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// 审计 P1-5：详情框边框主题刷新——detailView（发起页
    /// BearyWishCreateViewController 的 UITextView，非按钮）创建时
    /// borderColor = ink 20%（CGColor 赋值即固化），此前本文件无
    /// traitCollectionDidChange，深浅切换后边框停留在旧主题色；
    /// 色貌变化时按创建时原表达式重赋（复用 BearyButton.refreshChrome
    /// 范式；只重赋边框色，不动占位 / 计数 / 校验）。
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            detailView.layer.bearyDynamicBorderColor = BearyColors.ink.withAlphaComponent(0.2)
        }
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

    /// P0-13：关闭未保存提示——空内容（标题与详情均空白）直接关；有修改时先弹
    /// 确认，“继续编辑”留页、“放弃修改”才关（编辑资料页“放弃未保存的改动？”同款口径）。
    @objc private func closeTapped() {
        let hasTitle = !(titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDetail = !detailView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasTitle || hasDetail else {
            dismiss(animated: BearyMotion.animated(true), completion: nil)
            return
        }
        let alert = UIAlertController(title: "放弃未保存的改动？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel, handler: nil))
        alert.addAction(UIAlertAction(title: "放弃修改", style: .destructive, handler: { [weak self] _ in
            self?.dismiss(animated: BearyMotion.animated(true), completion: nil)
        }))
        present(alert, animated: BearyMotion.animated(true), completion: nil)
    }

    /// 30：字段级错误行显隐（显时松开 0 高约束，隐时压回 0 高，见属性注释）。
    private func setFieldErrorVisible(_ visible: Bool) {
        fieldErrorLabel.isHidden = !visible
        fieldErrorHeight?.isActive = !visible
    }

    /// 30：长度提示唯一刷新点——标题/详情计数与超限变红；超限时提交钮禁用
    /// （服务端同限，客户端先拦，超长 400 的 bad wish 仍由 submitTapped 字段级映射兜底）。
    private func updateLengthHints() {
        let titleCount = (titleField.text ?? "").count
        let detailCount = detailView.text.count
        titleCountLabel.text = "\(titleCount)/\(Self.titleLimit)"
        titleCountLabel.textColor = titleCount > Self.titleLimit ? BearyColors.red : BearyColors.gray
        detailCountLabel.text = "\(detailCount)/\(Self.detailLimit)"
        detailCountLabel.textColor = detailCount > Self.detailLimit ? BearyColors.red : BearyColors.gray
    }

    /// 11：提交钮启用态唯一入口——提交锁期间直接返回，标题变化不得重新启用提交钮。
    @objc private func titleChanged() {
        updateLengthHints()
        setFieldErrorVisible(false)
        guard !isSubmitting else { return }
        let trimmed = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ok = !trimmed.isEmpty && trimmed.count <= Self.titleLimit && detailView.text.count <= Self.detailLimit
        submitButton.isEnabled = ok
        submitButton.alpha = ok ? 1 : 0.4
    }

    func textViewDidChange(_ textView: UITextView) {
        detailPlaceholder.isHidden = !textView.text.isEmpty
        // 详情变化同样影响提交启用态（超 2000 即禁），复用 titleChanged 的唯一入口。
        titleChanged()
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
        guard !title.isEmpty, title.count <= Self.titleLimit, detailView.text.count <= Self.detailLimit else { return }
        let detail = detailView.text ?? ""
        isSubmitting = true
        setFieldErrorVisible(false)
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
                    // 30：超长 400 'bad wish' 走字段级提示（字段旁红字），不弹通用 toast；
                    // 其余失败映射不变（not_plus / rate_limited / 通用 toast）。
                    if case .server(let code) = err, code == "bad wish" {
                        self.setFieldErrorVisible(true)
                        return
                    }
                    let message: String
                    if case .server(let code) = err, code == "not_plus" {
                        message = "仅 Plus 会员可发起许愿"
                    } else if case .server(let code) = err, code == "rate_limited" {
                        message = "操作太频繁，请稍后再试"
                    } else {
                        message = "发布失败，请稍后再试"
                    }
                    BearyToast.show(in: self.view, message: message)
                }
            }
        }
    }
}
