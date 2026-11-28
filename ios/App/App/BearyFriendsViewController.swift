import UIKit

// MARK: - 好友第一期：好友列表页（底栏第四段“好友”的根页，关注/回关模型版）
//
// 位置：底栏第四段（首页、时间线、我的之后）；他人页不展示对方的好友列表，
// 本页只看自己的互关好友。段内两处分开，不混在一页：本页只列互关好友与取关，
// 会话列表不再从本页进：顶栏信封钮已去除，私信只从消息页的会话行进。
// 关注流已归并到首页顶栏“广场 / 正在关注”切换处（Li 2026-11-01 定），
// 好友段内不再另设关注流一处。
// 行：头像、名字、@handle；点人进对方公开主页；取关走行内 ⋯ 菜单里的删除
// （红字“取关”，二次确认后才发请求，静默解除、不发通知）。
// 游客不可见：入口在容器层已拦（游客点好友段走登录门）；本页再遇未登录
// 即走 onRequireLogin，不拉接口。

final class BearyFriendsViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {

    /// 好友行点按：传整条好友用户，容器负责打开对方主页。
    var onOpenUser: ((BearyAPI.FriendUser) -> Void)?
    /// 未登录时调用：容器接线到登录门。
    var onRequireLogin: (() -> Void)?
    /// 返回钮点按：只在从消息页打开时显，容器接线回消息页。
    var onBackToMessages: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    /// 自定义下拉指示器图标（32pt 官方刷新图标、灰色；平时 alpha 0，
    /// 下拉时淡入＋跟随旋转，刷新中常亮连续旋转）。
    private lazy var pullIconView = BearyRefreshIconView()

    /// 自定义下拉指示器（通知页同款）：固定高 116、藏在表内容上方
    /// （content y=-116..0），指示高按手指行程 ×0.48 阻尼（上限 116），
    /// 不拦截触摸；刷新中改固定 84 高。
    private lazy var pullView: UIView = {
        let pull = UIView()
        pull.backgroundColor = BearyColors.bg
        pull.isUserInteractionEnabled = false
        pull.frame = CGRect(x: 0, y: -116, width: 0, height: 116)
        pull.addSubview(pullIconView)
        NSLayoutConstraint.activate([
            pullIconView.centerXAnchor.constraint(equalTo: pull.centerXAnchor),
            pullIconView.bottomAnchor.constraint(equalTo: pull.bottomAnchor, constant: -14),
            pullIconView.widthAnchor.constraint(equalToConstant: 32),
            pullIconView.heightAnchor.constraint(equalToConstant: 32),
        ])
        return pull
    }()
    // 空／失败态走 BearyStateView（与首次加载态同槽位居中、互斥）。
    private let emptyStateView = BearyStateView()
    // 审计第 19 项：首次加载态复用 BearyStateView（转圈 +“加载中…”），不加骨架屏。
    // 只在“首次请求且尚无旧数据”时出现；有旧数据时保留内容后台刷新。
    private let firstLoadStateView = BearyStateView()
    private var firstLoadPending = true
    // 新行首次出现透明度过渡的已播记账（按好友 id/handle 键，已有行更新不重播）。
    private var fadedRowKeys = Set<String>()
    // 取关在途去重：同一好友的取关请求在途时再次确认直接丢弃（私信删除
    // deletingConversationPeerIds 同款口径）；请求结束（成功或失败）后移除。
    private var unfollowingUserIds: Set<Int> = []
    private let titleLabel = UILabel()
    private var topBarTopConstraint: NSLayoutConstraint?
    private var backButton: UIButton?
    private var titleLeadingConstraint: NSLayoutConstraint?
    private var friends: [BearyAPI.FriendUser] = []
    private var loading = false
    /// 自定义下拉头（通知页同款口径）：固定高 116、藏在表内容上方，指示高按
    /// 手指行程 ×0.48 阻尼（上限 116），32pt 官方刷新图标；触发 140pt、
    /// 刷新固定 84 高、进入／收回 0.38s。
    private var isCustomPullRefreshing = false
    /// 下拉收回动画在途旗：收回动画全程仍持刷新旗，跟随侧不中途重写 pullView.frame。
    private var customPullEndInFlight = false
    /// 一次拖动的 engage 锚点：只锁一次，中途不再凭 offset/inset 阈值清掉。
    private var pullEngageTranslation: CGFloat?
    private var needsReloadAfterUserChange = false
    private var loadFailed = false
    // 失败态全量·好友列表：已有内容时刷新失败的非阻断提示条，口径参照
    // #736 会话列表（常驻于顶栏下方、覆盖在列表顶部之上；只在 loadFailed
    // 且列表非空时显，空列表仍走居中空态文案，不与本条重复）。失败条不占位、
    // 不挤压列表：表顶恒贴顶栏，显隐只淡入淡出，列表 frame 与滚动位置全程
    // 不动，可见行不跳动；不清列表、不丢标题人数。
    private let refreshFailedBanner = UIView()
    private let refreshFailedLabel = UILabel()
    private let refreshFailedRetryButton = UIButton(type: .system)
    private var tableViewTopToTopBarConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        topBarTopConstraint = topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 19), maximumPointSize: 20)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "好友"
        topBar.addSubview(titleLabel)
        // 从消息页打开时的返回钮（回消息页；底栏根页默认隐藏，见 setOpenedFromMessages）。
        let backButton = UIButton(type: .system)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回消息页"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        backButton.isHidden = true
        topBar.addSubview(backButton)
        self.backButton = backButton

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = BearyColors.bg
        tableView.separatorStyle = .none
        // 行高定死 72（44 头像＋上下各 14，设计定值），不再走
        // automaticDimension 的拟合：拟合依赖 UIStackView 内在尺寸，
        // 拟合一旦失败行高可塌成 0，行在数据源里、屏上却没有
        // （好友 · 1 人零行实证）；本行内容固定单行名＋单行 handle，
        // 72 即设计高。
        tableView.rowHeight = 72
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(BearyFriendCell.self, forCellReuseIdentifier: "friendCell")
        tableView.addSubview(pullView)
        view.addSubview(tableView)

        // 已有内容刷新失败条：覆盖在顶栏下方、列表顶部之上（非弹框、非 toast，
        // 失败不消失直至下次成功）；点“重试”只重拉，不改列表与滚动位置。
        // 覆盖式底色须不透明，否则列表内容会透过半透明条显出来；底色 = bg 上
        // 叠 12% 语义红，与旧“red 0.12 透在 bg 上”的观感一致（深浅模式各自
        // 按当前 trait 混合）。
        refreshFailedBanner.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedBanner.backgroundColor = BearyColors.failureBannerBackground()
        refreshFailedBanner.isHidden = true
        refreshFailedBanner.alpha = 0
        view.addSubview(refreshFailedBanner)
        refreshFailedLabel.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        refreshFailedLabel.adjustsFontForContentSizeCategory = true
        refreshFailedLabel.textColor = BearyColors.ink
        refreshFailedLabel.text = NSLocalizedString("common.refresh_failed", comment: "")
        refreshFailedBanner.addSubview(refreshFailedLabel)
        refreshFailedRetryButton.translatesAutoresizingMaskIntoConstraints = false
        refreshFailedRetryButton.setTitle("重试", for: .normal)
        refreshFailedRetryButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        refreshFailedRetryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        refreshFailedRetryButton.setTitleColor(BearyColors.ink, for: .normal)
        refreshFailedRetryButton.accessibilityLabel = "重试"
        refreshFailedRetryButton.accessibilityHint = "重新拉取好友列表，不改变当前列表位置"
        refreshFailedRetryButton.addTarget(self, action: #selector(refreshFailedRetryTapped), for: .touchUpInside)
        refreshFailedRetryButton.bearyAddPressFeedback()
        refreshFailedBanner.addSubview(refreshFailedRetryButton)

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        view.addSubview(emptyStateView)

        firstLoadStateView.translatesAutoresizingMaskIntoConstraints = false
        firstLoadStateView.isHidden = true
        view.addSubview(firstLoadStateView)

        topBarTopConstraint?.isActive = true
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16)
        titleLeadingConstraint = titleLeading
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // V5：顶栏高改“下限 44”（紧凑档数值不动）＋标题底距兜底 ≥7：
            // 默认字号下 14（顶距）＋标题高＋7 ≈ 44，视觉与旧固定 44 一致；
            // 系统字号放大、标题变高时顶栏随之伸展，不再把标题底边裁在 44 内。
            // 横向护栏：标题右缘 ≤ 顶栏右缘 −16（私信钮已去除）。
            topBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            // 时间线同款：标题左对齐、左缘 16、顶距 14（时间线标题行栈顶 +14 同口径）。
            // 从消息页进来时左缘改 68（16 + 返回钮 44 + 间隙 8），见 setOpenedFromMessages。
            titleLeading,
            titleLabel.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: topBar.bottomAnchor, constant: -7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16),
            refreshFailedBanner.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            refreshFailedBanner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            refreshFailedBanner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            refreshFailedBanner.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            refreshFailedLabel.leadingAnchor.constraint(equalTo: refreshFailedBanner.leadingAnchor, constant: 16),
            refreshFailedLabel.centerYAnchor.constraint(equalTo: refreshFailedBanner.centerYAnchor),
            refreshFailedRetryButton.trailingAnchor.constraint(equalTo: refreshFailedBanner.trailingAnchor, constant: -16),
            refreshFailedRetryButton.centerYAnchor.constraint(equalTo: refreshFailedBanner.centerYAnchor),
            refreshFailedRetryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            refreshFailedRetryButton.leadingAnchor.constraint(greaterThanOrEqualTo: refreshFailedLabel.trailingAnchor, constant: 8),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
            // 首次加载态与空态同槽位居中（互斥显隐，见 load/updateTitleAndEmptyState）。
            firstLoadStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            firstLoadStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            firstLoadStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            firstLoadStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])
        // 表顶恒贴顶栏：失败条覆盖在列表顶部之上、不占位，故表顶约束只有
        // 这一条，不随失败条显隐切换，列表 frame 全程不动。
        tableViewTopToTopBarConstraint = tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor)
        tableViewTopToTopBarConstraint?.isActive = true

        NotificationCenter.default.addObserver(self, selector: #selector(friendsChanged), name: .bearyFriendsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(userBlocked(_:)), name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(userChanged), name: .bearyUserDidChange, object: nil)
        load()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 底栏浮在页底：表底补 80 + 安全区底（与消息页同口径），末行不被底栏盖住。
        let bottom = 80 + view.safeAreaInsets.bottom
        if tableView.contentInset.bottom != bottom {
            tableView.contentInset.bottom = bottom
            tableView.scrollIndicatorInsets.bottom = bottom
        }
        if tableView.bounds.width > 0 && pullView.frame.width != tableView.bounds.width {
            pullView.frame.size.width = tableView.bounds.width
        }
    }

    /// 容器顶栏显隐同步：顶栏显示时本页顶栏顶距 = 安全区顶 + 60（顶栏内容区高），
    /// 顶栏收起时顶距 0（与 Feed/消息页的 applyHeaderTopInset 同口径；本页顶栏
    /// 是固定条而非滚动内边距，故改约束常量而非 contentInset）。
    func applyHeaderTopInset(visible: Bool) {
        // 开发者模式横幅（36pt，见 BearyDeveloperMode.devBannerInset）：开着时顶栏内容下移清过横幅。
        topBarTopConstraint?.constant = (visible ? 60 : 0) + BearyDeveloperMode.shared.devBannerInset
    }

    /// 从消息页打开时显返回钮（回消息页），标题左缘同步让位；
    /// 底栏根页不显，布局与原来一致。容器在每次进好友页时按来源重设。
    func setOpenedFromMessages(_ opened: Bool) {
        backButton?.isHidden = !opened
        titleLeadingConstraint?.constant = opened ? 68 : 16
    }

    @objc private func backTapped() {
        onBackToMessages?()
    }

    /// 同 tab 重拍口径（容器 showPage 用）：回顶 + 刷新入口。
    var isAtTop: Bool {
        tableView.contentOffset.y <= -tableView.contentInset.top + 1
    }

    var isRefreshingForRetap: Bool {
        loading
    }

    func scrollToTop() {
        tableView.setContentOffset(CGPoint(x: 0, y: -tableView.contentInset.top), animated: BearyMotion.animated(true))
    }

    func refresh() {
        if isCustomPullRefreshing || (firstLoadPending && loading) {
            return
        }
        beginCustomPullRefresh()
    }

    /// 自定义下拉指示器跟随：手指行程（pan 手势自顶部锚点起算）× 0.48 阻尼、
    /// 上限 116；指示高 ≥67.2 时转满一圈（= 触发行程 140pt × 0.48）。
    /// 指示器是表内子视图：屏内底边固定为指示高，顶边随表回弹裁剪。
    /// 锚点一次拖动只锁一次：中途不再凭 offset/inset 阈值清掉——顶栏显隐
    /// 改 contentInset.top 或重载顶 offset，都会把阈值顶到手指下面，旧口径
    /// 一清锚点 fingerRaw 即归零、指示高塌掉，图标还没触发就缩回去。
    /// 锚点只在拖动结束清（scrollViewDidEndDragging 与下方 !isDragging 分支）。
    private func updateCustomPullIndicator() {
        if isCustomPullRefreshing {
            return
        }
        if !tableView.isDragging {
            pullEngageTranslation = nil
            pullView.frame = CGRect(x: 0, y: -116, width: tableView.bounds.width, height: 116)
            pullIconView.setPullProgress(0)
            return
        }
        let contentRaw = max(0, -(tableView.contentOffset.y + tableView.contentInset.top))
        let panTranslation = tableView.panGestureRecognizer.translation(in: tableView).y
        if tableView.contentOffset.y <= -tableView.contentInset.top && pullEngageTranslation == nil {
            pullEngageTranslation = panTranslation
        }
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        let indicatorHeight = min(fingerRaw * 0.48, 116)
        pullView.frame = CGRect(x: 0, y: indicatorHeight - 116 - contentRaw, width: tableView.bounds.width, height: 116)
        if indicatorHeight <= 0 {
            pullIconView.setPullProgress(0)
        } else {
            let progress = min(1, indicatorHeight / 67.2)
            pullIconView.setPullProgress(progress)
        }
    }

    /// 自定义下拉刷新进入：指示固定 84 高 + 转圈，回包到即收回
    /// （无 0.5 秒最低展示）。load() 回包终点调 endCustomPullRefresh 收回；
    /// load() 因在途直接返回时不收回——在途那次结束时收回，不丢刷新。
    private func beginCustomPullRefresh() {
        if isCustomPullRefreshing || (firstLoadPending && loading) {
            return
        }
        isCustomPullRefreshing = true
        pullIconView.startSpinning()
        // 回程一次到位：先掐断松手后的表减速/回弹（位置不动、仅停掉动量）。
        // 否则表自带物理动画会与下面 easing 动画双路驱动 contentOffset：
        // 先随惯性多下一截、再被拉回 84 位，即“先下降一点再回去”。
        tableView.setContentOffset(tableView.contentOffset, animated: false)
        let pullIn = {
            self.tableView.contentInset.top = 84 // beary-lint: allow
            self.tableView.scrollIndicatorInsets.top = 84
            self.tableView.contentOffset = CGPoint(x: 0, y: -84)
            self.pullView.frame = CGRect(x: 0, y: -84, width: self.tableView.bounds.width, height: 84)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullIn()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullIn)
        }
        load()
    }

    /// 进页重拉（容器 showPage 切入时调，与消息页同口径）：本页此前只在
    /// viewDidLoad 拉一次；首拉失败／回空后切走再进不再重拉，会一直停在
    /// 失败／空态。进页即重拉自愈；在途时 load() 内守卫直接返回，不重复请求。
    func pageDidEnter() {
        load()
    }

    private func endCustomPullRefresh() {
        if !isCustomPullRefreshing || customPullEndInFlight {
            return
        }
        customPullEndInFlight = true
        // 收回动画全程仍持刷新旗：跟随侧不中途重写 pullView.frame。
        // 结束时只收指示器——若刷新在途用户已滑到深处（或仍按住拖动），
        // 不再把 contentOffset 拽回 0 顶部，只复位内边距、藏指示头，留在原位置；
        // 仍停在下拉位的才按旧口径回到 0（指示区须收掉）。
        // 下拉位 = -84（见 beginCustomPullRefresh）；8pt 容差内算仍在下拉位。
        let stillAtPullPosition = !self.tableView.isDragging
            && self.tableView.contentOffset.y <= -84 + 8
        // 动量截断（进入侧同款）：只在仍停在下拉位时——此时收回动画要接管
        // offset；松手后的表减速若还在跑，会与收回 easing 双路驱动
        // contentOffset，图标先往下掉一下再上去；先掐断再播动画。
        // 用户已滑走时 offset 不参与收回动画，不碰他的滚动。
        if stillAtPullPosition {
            tableView.setContentOffset(tableView.contentOffset, animated: false)
        }
        let pullOut = {
            self.tableView.contentInset.top = 0
            self.tableView.scrollIndicatorInsets.top = 0
            if stillAtPullPosition {
                self.tableView.contentOffset = CGPoint(x: 0, y: 0)
            }
            self.pullView.frame = CGRect(x: 0, y: -116, width: self.tableView.bounds.width, height: 116)
        }
        if UIAccessibility.isReduceMotionEnabled {
            pullOut()
            self.isCustomPullRefreshing = false
            self.customPullEndInFlight = false
            self.pullIconView.stopSpinning()
        } else {
            UIView.animate(withDuration: BearyMotion.screen, delay: 0, options: [.curveEaseOut, .beginFromCurrentState], animations: pullOut, completion: { _ in
                self.isCustomPullRefreshing = false
                self.customPullEndInFlight = false
                self.pullIconView.stopSpinning()
            })
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateCustomPullIndicator()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        // 自定义下拉触发：手指原始行程满 140pt 松手才刷新。
        let panTranslation = scrollView.panGestureRecognizer.translation(in: scrollView).y
        let fingerRaw = max(0, panTranslation - (pullEngageTranslation ?? panTranslation))
        pullEngageTranslation = nil
        if fingerRaw >= 140 && !isCustomPullRefreshing && !(firstLoadPending && loading) {
            // 自定义下拉触发（满 140pt 松手）给一次轻触觉；程序触发的 refresh() 不走这里。
            BearyHaptics.press()
            beginCustomPullRefresh()
        }
    }

    @objc private func refreshFailedRetryTapped() {
        // 只重拉：load() 在途时直接返回、不重复请求；成功才清条，
        // 失败条继续留着；全程不清 friends、不 scrollToTop。
        load()
    }

    @objc private func friendsChanged() {
        // 别处回关/取关后本页若还开着，重拉一次（不叠加 toast、不抢焦点）。
        load()
    }

    /// 个人页拉黑后就地删行：拉黑成功只发 .bearyDidBlockUser（object 为对方 id，
    /// BearyNativeCommon confirmBlock），不发 .bearyFriendsChanged，取关链路不动；
    /// 拉黑即断互关，被拉黑者不再是好友，点按即最终态——只删该行，不重拉。
    /// 不在列表里时（别处拉黑的非好友）直接忽略。
    @objc private func userBlocked(_ note: Notification) {
        guard let userId = note.object as? Int,
              let index = friends.firstIndex(where: { $0.id == userId }) else { return }
        friends.remove(at: index)
        updateTitleAndEmptyState()
        tableView.deleteRows(at: [IndexPath(row: index, section: 0)], with: .fade)
    }

    @objc private func userChanged() {
        // 账号切换：旧号列表不得残留。已登录重拉新号；已退出只清空、不弹登录门
        //（容器在退出翻转时自会处理页跳转，本页不抢弹）。
        if SessionManager.shared.isLoggedIn {
            friends = []
            loadFailed = false
            // 新号的首次加载重新走加载态（旧号加载态不得残留到新号）。
            firstLoadPending = true
            updateTitleAndEmptyState()
            tableView.reloadData()
            if loading {
                needsReloadAfterUserChange = true
            } else {
                load()
            }
        } else {
            friends = []
            loadFailed = false
            firstLoadPending = true
            needsReloadAfterUserChange = false
            updateTitleAndEmptyState()
            tableView.reloadData()
        }
    }

    private func load() {
        guard SessionManager.shared.isLoggedIn else {
            endCustomPullRefresh()
            onRequireLogin?()
            return
        }
        guard !loading else { return }
        loading = true
        loadFailed = false
        // 审计第 19 项：首次无数据才显加载态（下拉刷新自带转圈时不叠加）；
        // 有旧数据时不遮内容，后台刷新完直接换行。
        if firstLoadPending && friends.isEmpty && !isCustomPullRefreshing {
            emptyStateView.isHidden = true
            firstLoadStateView.configure(kind: .loading, title: "加载中…", subtitle: nil, iconName: nil, actionTitle: nil)
            firstLoadStateView.isHidden = false
        }
        let requestUid = SessionManager.shared.currentUser?.id
        // r28-2：发起时同时捕获鉴权代次——只比账号 ID 时，A→B→A
        // 快切后旧 A 请求回包的账号 ID 再次相等，会通过校验、把切号前
        // 的陈旧快照当作有效回包渲染；authEpoch 每次权威登录态变迁
        // 单调 +1，旧回包凭代次丢弃（同款修法见 #1126 DM 会话页）。
        let requestEpoch = BearyAPI.shared.authEpoch
        BearyAPI.shared.fetchFriends { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loading = false
                self.endCustomPullRefresh()
                self.firstLoadStateView.isHidden = true
                // 切号后到达的旧回包直接丢弃（账号 ID + 代次双重校验；
                // A→B→A 时账号 ID 再次相等，代次不等仍丢弃）；若新号重拉挂起，补发一次。
                if SessionManager.shared.currentUser?.id != requestUid
                    || BearyAPI.shared.authEpoch != requestEpoch {
                    if self.needsReloadAfterUserChange {
                        self.needsReloadAfterUserChange = false
                        self.load()
                    } else if SessionManager.shared.currentUser?.id == requestUid {
                        // 账号没变、只是代次变了（在途时鉴权代次被推过，
                        // 如 401 清态后又恢复）：旧回包丢弃后补拉一次。
                        // 此时 loading 已置 false，load() 内守卫不拦；
                        // 代次稳定后第二次回包即正常渲染，不会循环触发
                        //（代次只在鉴权变迁时单调 +1，401 本身会走下
                        // 面分支，不进补拉）。
                        self.load()
                    } else {
                        // 真切号／已退出：恢复与当前登录态一致的空态与
                        // 标题，不留空白页（此前直接 return，加载态已藏、
                        // 空态仍藏、friends 仍空，页上只剩标题）。
                        self.updateTitleAndEmptyState()
                        self.tableView.reloadData()
                    }
                    return
                }
                self.firstLoadPending = false
                switch result {
                case .success(let list):
                    self.friends = list.resolvedFriends
                    self.loadFailed = false
                case .failure:
                    // 失败不拿半截列表渲染（防把“未拉到”画成“没有好友”）。
                    self.loadFailed = true
                }
                self.updateTitleAndEmptyState()
                self.tableView.reloadData()
                // r28-2：匹配分支同样消费切号挂起旗——此前只在不匹配
                // 分支清旗，匹配分支既不清旗也不补拉，应补拉的新请求
                // 会被静默吞掉、旗标残留。先渲染本次有效回包，再清旗
                // 补拉一次；旗已在补拉前清掉，不会循环触发。
                if self.needsReloadAfterUserChange {
                    self.needsReloadAfterUserChange = false
                    self.load()
                }
            }
        }
    }

    private func updateTitleAndEmptyState() {
        // 标题行带人数：只要列表非空就显人数，刷新失败也不退成光秃标题
        //（旧口径 loadFailed 时一律只显“好友”，把失败画成人数丢失）；
        // 只有空列表时只显“好友”，不把失败画成 0 人。
        titleLabel.text = friends.isEmpty ? "好友" : "好友 · \(friends.count)人"
        if loadFailed && friends.isEmpty {
            // 审计 U3：失败态给重试钮（与消息页同款）：点按即重拉；下拉手势仍可用。
            emptyStateView.configure(kind: .error, title: "加载失败", subtitle: "下拉重试", iconName: nil, actionTitle: "重试", onAction: { [weak self] in self?.refresh() })
            emptyStateView.isHidden = false
            setRefreshFailedBannerVisible(false)
        } else if friends.isEmpty {
            emptyStateView.configure(kind: .empty, title: "还没有互关好友", subtitle: "关注对方、等对方回关后就会出现在这里", iconName: nil, actionTitle: nil)
            emptyStateView.isHidden = false
            setRefreshFailedBannerVisible(false)
        } else {
            emptyStateView.isHidden = true
            // 已有内容时失败不再零反馈：旧列表原样保留，顶栏下出
            // “未能刷新 · 重试”常驻条；成功（loadFailed=false）时收起。
            setRefreshFailedBannerVisible(loadFailed)
        }
    }

    private func setRefreshFailedBannerVisible(_ visible: Bool) {
        // 覆盖式：只淡入淡出，不碰表顶约束与 contentOffset，列表不跳动。
        // 减动效直设终值；收起动画被新显隐打断时 completion 的 finished 为
        // false，不藏条，防新显的条被旧收起动画的 completion 误藏。
        if visible {
            refreshFailedBanner.isHidden = false
            guard BearyMotion.animated(true) else {
                refreshFailedBanner.alpha = 1
                return
            }
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                self.refreshFailedBanner.alpha = 1
            })
        } else {
            guard BearyMotion.animated(true) else {
                refreshFailedBanner.alpha = 0
                refreshFailedBanner.isHidden = true
                return
            }
            UIView.animate(withDuration: BearyMotion.normal, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: {
                self.refreshFailedBanner.alpha = 0
            }, completion: { finished in
                if finished {
                    self.refreshFailedBanner.isHidden = true
                }
            })
        }
    }

    // MARK: - Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        friends.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "friendCell", for: indexPath) as! BearyFriendCell
        let user = friends[indexPath.row]
        // 复用 cell 永不以不可见态起步：willDisplay 的入场淡入从
        // alpha 0 起播，prepareForReuse 从不复位 alpha/transform，
        // 中途打断的淡入会把近 0 的 alpha 带进下一行，行在却看不见。
        cell.alpha = 1
        cell.transform = .identity
        cell.configure(user: user) { [weak self] button in
            self?.presentFriendMenu(user: user, sourceButton: button)
        }
        return cell
    }

    // 审计 M4：新行首次出现错峰滑入（0.26s、6pt 位移、0.03s 步进、最多延迟 0.24s，
    // 广场同款；减动效直设终值）；已播过的行再次出现（滚动回 / reloadData 更新）
    // 只复位 alpha 与 transform，不重播。复用 cell 的 alpha 与 transform 必须显式
    // 复位，否则上行动画中途的 cell 会带着半透明/位移进新行。
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard indexPath.row < friends.count else { return }
        let user = friends[indexPath.row]
        let key = user.id.map { "friend-\($0)" } ?? "friend-\(user.handle ?? user.displayName ?? "")"
        if fadedRowKeys.contains(key) {
            cell.alpha = 1
            cell.transform = .identity
            return
        }
        fadedRowKeys.insert(key)
        guard BearyMotion.animated(true) else {
            cell.alpha = 1
            cell.transform = .identity
            return
        }
        // 序号取当前可见行中的位置（未计入时退回行号），与广场 stagger 同口径。
        cell.alpha = 0
        cell.transform = CGAffineTransform(translationX: 0, y: 6)
        let visible = (tableView.indexPathsForVisibleRows ?? []).sorted()
        let order = visible.firstIndex(of: indexPath) ?? indexPath.row
        let delay = min(Double(order) * 0.03, 0.24)
        UIView.animate(withDuration: BearyMotion.normal, delay: delay, options: [.curveEaseOut, .allowUserInteraction], animations: {
            cell.alpha = 1
            cell.transform = .identity
        })
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        guard indexPath.row < friends.count else { return }
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressDown(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        BearyIconMotion.rowPressUp(on: cell.contentView)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onOpenUser?(friends[indexPath.row])
    }

    /// 行内 ⋯ 菜单：取关为红字 destructive；点取关后再弹一次确认框，
    /// 确认后行立即删（乐观更新；Li 2026-11-28 定，第六轮审计 N5 例外作废），
    /// 失败把行插回原位＋拒绝反馈＋toast；
    /// 成功后清缓存并广播，各列表页据此重拉（取关静默解除，不发通知）。
    private func presentFriendMenu(user: BearyAPI.FriendUser, sourceButton: UIButton) {
        guard let userId = user.id else { return }
        BearyConfirmSheet.show(from: self, title: "", message: nil, actions: [
            BearyConfirmSheet.Action(title: "取消关注", style: .destructive) { [weak self] in
                guard let self = self else { return }
                BearyFriends.confirmUnfollowAlert(from: self, displayName: user.displayName ?? "", mutual: true) { [weak self] in
                    guard let self = self else { return }
                    guard let removedIndex = self.friends.firstIndex(where: { $0.id == userId }) else { return }
                    guard !self.unfollowingUserIds.contains(userId) else { return }
                    self.unfollowingUserIds.insert(userId)
                    // 乐观更新：点确认行立即删，留一份该行数据＋原 index 供失败回滚。
                    let removedFriend = self.friends[removedIndex]
                    self.friends.remove(at: removedIndex)
                    self.updateTitleAndEmptyState()
                    self.tableView.deleteRows(at: [IndexPath(row: removedIndex, section: 0)], with: .fade)
                    // r28-4：取关失败回滚只认发起账号。发起时同拍账号 id＋代次
                    //（通知页／引用面板同款口径），切号后到达的旧号失败回包整单丢弃。
                    let requestAccountId = BearyAPI.shared.authAccountId
                    let requestEpoch = BearyAPI.shared.authEpoch
                    BearyAPI.shared.unfollowFriend(userId: userId) { [weak self] result in
                        DispatchQueue.main.async {
                            guard let self = self else { return }
                            self.unfollowingUserIds.remove(userId)
                            switch result {
                            case .success:
                                // 请求期间列表可能已重拉、该行又回来了，成功时仍在就再删一次。
                                if let currentIndex = self.friends.firstIndex(where: { $0.id == userId }) {
                                    self.friends.remove(at: currentIndex)
                                    self.updateTitleAndEmptyState()
                                    self.tableView.deleteRows(at: [IndexPath(row: currentIndex, section: 0)], with: .fade)
                                }
                                BearyFriends.clearDiaryCachesAndNotify()
                            case .failure:
                                // r28-4：账号或代次已变，说明回包属于旧账号——整单丢弃，
                                // 不 toast、不抖动、不插回，避免把旧账号的反馈给到新账号。
                                guard requestAccountId == BearyAPI.shared.authAccountId,
                                      requestEpoch == BearyAPI.shared.authEpoch else { return }
                                // 失败回滚：行插回原位（重拉已把人带回来时不再重复插），
                                // 再给震动＋拒绝音＋toast；震动＋拒绝音不依赖 cell 是否可见，
                                // 只有摇头仍只在行可见时执行。
                                if !self.friends.contains(where: { $0.id == userId }) {
                                    let insertIndex = min(removedIndex, self.friends.count)
                                    self.friends.insert(removedFriend, at: insertIndex)
                                    self.updateTitleAndEmptyState()
                                    self.tableView.insertRows(at: [IndexPath(row: insertIndex, section: 0)], with: .fade)
                                }
                                BearyIconMotion.playDenyFeedback()
                                if let currentIndex = self.friends.firstIndex(where: { $0.id == userId }),
                                   let cell = self.tableView.cellForRow(at: IndexPath(row: currentIndex, section: 0)) {
                                    BearyIconMotion.denyShake(on: cell, key: "bearyDenyShake")
                                }
                                BearyToast.show(in: self.view, message: NSLocalizedString("follow.toast.unfollowFailed", comment: ""))
                            }
                        }
                    }
                }
            },
        ])
    }
}

// MARK: - 行 Cell（头像首字母兜底 + 行内 ⋯ 钮；无自绘图形）

private final class BearyFriendCell: UITableViewCell {

    // C3：头像走统一 BearyAvatarView（44 圆角 22、首字母占位、失败重试内含）。
    private let avatarView = BearyAvatarView()
    private let nameLabel = UILabel()
    private let handleLabel = UILabel()
    /// 名字＋handle 纵向栈：整块相对头像垂直居中（约束见 init）。
    private let textStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 1
        stack.alignment = .fill
        return stack
    }()
    private let separatorView = UIView()
    private var moreHandler: ((UIButton) -> Void)?

    private lazy var moreButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(BearyIconImages.image(named: "icon_more", pointSize: 24), for: .normal)
        button.tintColor = BearyColors.ink
        button.accessibilityLabel = "更多"
        button.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
        button.bearyAddPressFeedback()
        return button
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = BearyColors.bg
        selectionStyle = .none

        avatarView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = BearyDynamicType.cardTitleFont()
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = BearyColors.ink
        nameLabel.numberOfLines = 1
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        handleLabel.adjustsFontForContentSizeCategory = true
        handleLabel.textColor = BearyColors.gray
        handleLabel.numberOfLines = 1

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = BearyColors.line
        contentView.addSubview(avatarView)
        textStack.addArrangedSubview(nameLabel)
        textStack.addArrangedSubview(handleLabel)
        contentView.addSubview(textStack)
        contentView.addSubview(moreButton)
        contentView.addSubview(separatorView)
        // 名字＋handle 整块相对头像垂直居中：栈 centerY 钉头像 centerY（999，
        // 大字号下上下守卫先 binding 时让位；守卫对称故回落时仍居中）；
        // 无 handle 时栈自动收起单行名字，同样居中。行高仍由头像与栈共同决定，
        // 头像垂直居中、上下各留最小 14（行高下限 72 兜底）。
        let textStackCenterY = textStack.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor)
        textStackCenterY.priority = .defaultHigh
        NSLayoutConstraint.activate([
            avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            avatarView.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 14),
            avatarView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            textStackCenterY,
            textStack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 14),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -14),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 71),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),
            // 审计低风险项：行底 0.5pt 分隔线（与日记行底边同口径）。
            separatorView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            separatorView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorView.heightAnchor.constraint(equalToConstant: 0.5),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 复位入场淡入留下的视觉状态：不复位时，中途打断的淡入会把
        // 近 0 的 alpha / 位移带进下一行，行在数据源里、屏上却看不见。
        alpha = 1
        transform = .identity
        nameLabel.text = nil
        avatarView.reset()
        handleLabel.text = nil
        handleLabel.isHidden = true
        moreHandler = nil
    }

    func configure(user: BearyAPI.FriendUser, onMore: @escaping (UIButton) -> Void) {
        moreHandler = onMore
        // 无昵称的账号用 @handle 兜底（服务端 display_name 为空时），
        // 再无 handle 才走通用「Beary 用户」；行绝不因缺昵称被丢。
        let displayName: String
        if let name = user.displayName, !name.isEmpty {
            displayName = name
        } else if let handle = user.handle, !handle.isEmpty {
            displayName = "@\(handle)"
        } else {
            displayName = NSLocalizedString("emote.posters.fallback_display_name", comment: "")
        }
        nameLabel.text = displayName
        if let handle = user.handle, !handle.isEmpty {
            handleLabel.text = "@\(handle)"
            handleLabel.isHidden = false
        } else {
            handleLabel.text = nil
            handleLabel.isHidden = true
        }
        // C3：头像加载/占位/重试全走 BearyAvatarView（与旧 configure 同口径：
        // 有图加载、无图首字母占位、失败占位＋重试；复用前 reset 已清旧任务）。
        avatarView.configure(displayName: displayName, avatarURL: user.avatarUrl.flatMap { BearyImageURLs.avatarURL($0) }, ownerID: user.id)
    }

    @objc private func moreTapped() {
        moreHandler?(moreButton)
    }
}
