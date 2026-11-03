import UIKit

// MARK: - 消息页（Li 2026-11-03 定）：底栏“消息”段的根页
//
// 好友页改成消息页：铃铛通知＋私信同页分两组——上面“通知”，下面“私信”。
// 两组不另写逻辑，各复用既有页实例：通知组是 BearyNotificationsViewController
// （关注卡回关按实时关系等行为原样保留），私信组是
// BearyDMConversationsViewController（未读角标蓝底白字原样保留）。
// 两组表内滚动交外层滚动视图：外层一个 UIScrollView 纵向排布，
// 每组容器高由组内表内容高回调驱动（见两组各自的 onContentHeightChanged）。
// 顶栏：左边标题“消息”，右上角用户列表按钮（双人图标 44×44），
// 点进原好友列表页——原页面只换入口，不重做（容器接线 showPage(.friends)）。
// 底栏“好友”段同步改叫“消息”、图标换气泡，见 SceneDelegate 底栏接线。
// 下拉刷新：外层不另挂刷新头（内层通知页的自定义下拉头在嵌入态下会
// 落在组顶、与外层圈双显），刷新走同 tab 重拍、进页门控、聊天关闭回调
// 与关系／账号广播——两组各自原有的刷新路径（见 refresh / pageDidEnter /
// refreshGroups），不在此另起一套。
// 已看水印：进消息页本身不记通知已看；通知组实际出现在滚动视口内时
// 才记一次／访问（见 updateNotifSeenIfVisible）；聊天关闭回填、私信组
// 刷新都不记。铃铛角标数字仍走服务端未读数，不受 seen 水印影响。

final class BearyMessagesViewController: UIViewController {

    /// 未登录时调用：容器接线到登录门。
    var onRequireLogin: (() -> Void)?
    /// 顶栏用户列表钮点按：容器接线到原好友列表页。
    var onOpenUserList: (() -> Void)?
    /// 通知行点按（日记去向）：传日记 id，容器接线到 gotoEntry。
    var onOpenEntry: ((String) -> Void)?
    /// 通知行点按（用户去向）：传用户 id，容器接线到对方主页。
    var onOpenUser: ((Int) -> Void)?
    /// 私信行／通知私信行点按：传对方用户，容器接线到聊天页。
    var onOpenDM: ((BearyAPI.FriendUser) -> Void)?

    private let scrollView = UIScrollView()
    private let titleLabel = UILabel()
    private var topBarTopConstraint: NSLayoutConstraint?
    private let notifContainer = UIView()
    private let conversationsContainer = UIView()
    private var notifHeightConstraint: NSLayoutConstraint?
    private var conversationsHeightConstraint: NSLayoutConstraint?

    /// 通知组：既有通知页实例（与铃铛页同类、不同实例，见容器接线注释）。
    private let notifChild = BearyNotificationsViewController()
    /// 私信组：既有会话列表页实例（与会话列表页同类、不同实例）。
    private let conversationsChild = BearyDMConversationsViewController()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg

        let topBar = UIView()
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)
        topBarTopConstraint = topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 19))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.ink
        titleLabel.text = "消息"
        topBar.addSubview(titleLabel)
        // 顶栏右钮：用户列表（双人图标），点进原好友列表页。
        let userListButton = UIButton(type: .system)
        userListButton.translatesAutoresizingMaskIntoConstraints = false
        userListButton.setImage(BearyIconImages.image(named: "icon_users", pointSize: 20), for: .normal)
        userListButton.tintColor = BearyColors.ink
        userListButton.accessibilityLabel = "用户列表"
        userListButton.addTarget(self, action: #selector(userListTapped), for: .touchUpInside)
        userListButton.bearyAddPressFeedback()
        topBar.addSubview(userListButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        // 外层滚动视图不自动叠加安全区内边距：顶栏已是固定条，底 inset 手动补
        //（viewDidLayoutSubviews，底栏浮在页底、末行不被盖住，与好友页同口径）。
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 0
        scrollView.addSubview(stack)

        notifContainer.translatesAutoresizingMaskIntoConstraints = false
        conversationsContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(notifContainer)
        stack.addArrangedSubview(conversationsContainer)
        notifHeightConstraint = notifContainer.heightAnchor.constraint(equalToConstant: 0)
        conversationsHeightConstraint = conversationsContainer.heightAnchor.constraint(equalToConstant: 0)
        notifHeightConstraint?.isActive = true
        conversationsHeightConstraint?.isActive = true

        topBarTopConstraint?.isActive = true
        NSLayoutConstraint.activate([
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: userListButton.leadingAnchor, constant: -8),
            userListButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            userListButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            userListButton.widthAnchor.constraint(equalToConstant: 44),
            userListButton.heightAnchor.constraint(equalToConstant: 44),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        embed(child: notifChild, in: notifContainer)
        embed(child: conversationsChild, in: conversationsContainer)

        // 通知组接线与铃铛页同口径（onSystemNotificationSelected 不接线，
        // 系统行默认行为留在通知页内部，与铃铛页一致）。
        notifChild.onEntrySelected = { [weak self] entryId in self?.onOpenEntry?(entryId) }
        notifChild.onRequireLogin = { [weak self] in self?.onRequireLogin?() }
        notifChild.onOpenUser = { [weak self] userId in self?.onOpenUser?(userId) }
        notifChild.onOpenDM = { [weak self] peer in self?.onOpenDM?(peer) }
        // 嵌入态：表内滚动交外层，表头标题改作“通知”组头；容器顶 inset 收起。
        notifChild.setEmbedded()
        notifChild.applyHeaderTopInset(visible: false)
        notifChild.onContentHeightChanged = { [weak self] height in
            guard let self = self, self.notifHeightConstraint?.constant != height else { return }
            self.notifHeightConstraint?.constant = height
        }

        // 私信组接线与会话列表页同口径；嵌入态无返回钮（组头只留“私信”标题）。
        conversationsChild.onRequireLogin = { [weak self] in self?.onRequireLogin?() }
        conversationsChild.onOpenChat = { [weak self] conversation in
            guard let peer = conversation.peer, peer.id != nil else { return }
            self?.onOpenDM?(peer)
        }
        conversationsChild.setEmbedded()
        conversationsChild.applyHeaderTopInset(visible: false)
        conversationsChild.onContentHeightChanged = { [weak self] height in
            guard let self = self, self.conversationsHeightConstraint?.constant != height else { return }
            self.conversationsHeightConstraint?.constant = height
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // 底栏浮在页底：外层表底补 80 + 安全区底（与好友／会话页同口径），
        // 末行不被底栏盖住。
        let bottom = 80 + view.safeAreaInsets.bottom
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset.bottom = bottom
            scrollView.scrollIndicatorInsets.bottom = bottom
        }
        updateNotifSeenIfVisible()
    }

    /// 通知组可见性门控：只在通知组实际出现在滚动视口内时记已看。
    /// 进消息页本身不记；首进时通知组在顶部、一般立即可见；此前已滚到
    /// 私信组、切回后仍在深位时不记，滚回顶部露出通知组时才记。
    /// 记一次／访问（守卫在子页 markNotifPageEntered，离页复位）。
    private func updateNotifSeenIfVisible() {
        // 容器切页只改 isHidden：离页、旋转等布局回调也可能走到这里，
        // 只有本页真正在窗内且未隐藏时才按可见性记。
        guard view.window != nil, !view.isHidden else { return }
        let groupFrame = notifContainer.convert(notifContainer.bounds, to: scrollView)
        let visibleRect = CGRect(origin: scrollView.contentOffset, size: scrollView.bounds.size)
        let intersection = groupFrame.intersection(visibleRect)
        guard intersection.height >= 24 else { return }
        notifChild.markNotifGroupViewed()
    }

    private func embed(child: UIViewController, in container: UIView) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: container.topAnchor),
            child.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }

    @objc private func userListTapped() {
        onOpenUserList?()
    }

    /// 容器顶栏显隐同步：顶栏显示时本页顶栏顶距 = 安全区顶 + 60（顶栏内容区高），
    /// 顶栏收起时顶距 0（与好友列表页的 applyHeaderTopInset 同口径；本页顶栏
    /// 是固定条而非滚动内边距，故改约束常量而非 contentInset）。
    func applyHeaderTopInset(visible: Bool) {
        topBarTopConstraint?.constant = visible ? 60 : 0
    }

    /// 同 tab 重拍口径（容器 showPage 用）：回顶 + 刷新入口。
    var isAtTop: Bool {
        scrollView.contentOffset.y <= -scrollView.contentInset.top + 1
    }

    var isRefreshingForRetap: Bool {
        notifChild.isRefreshingForRetap || conversationsChild.isRefreshingForRetap
    }

    func scrollToTop() {
        scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.contentInset.top), animated: BearyMotion.animated(true))
    }

    /// 重拍刷新：两组各走原有刷新入口（通知组自定义下拉头、会话组重拉）。
    func refresh() {
        notifChild.refresh()
        conversationsChild.refresh()
    }

    /// 容器切页进页钩子（与铃铛页 showPage 分支同口径）：恢复通知轮询，
    /// 未读数变了才整页重拉（门控在通知页内部）；进页不记已看，已看由
    /// 通知组可见性门控记（铃铛页进页仍走记已看的原口径）。
    func pageDidEnter() {
        notifChild.pageDidEnter()
        notifChild.refreshListIfUnreadChangedWithoutMarking()
        updateNotifSeenIfVisible()
    }

    /// 容器切页离页钩子：停通知轮询、写回通知缓存（与铃铛页同口径）。
    func pageDidLeave() {
        notifChild.pageDidLeave()
    }

    /// 聊天页关闭后的刷新（容器 presentDMChat onClosed 接线）：会话组重拉
    /// （新消息改摘要／未读），通知组按未读门控刷新、不记已看
    /// （私信组路径不触发通知已看）。
    func refreshGroups() {
        conversationsChild.refresh()
        notifChild.refreshListIfUnreadChangedWithoutMarking()
    }
}

extension BearyMessagesViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateNotifSeenIfVisible()
    }
}
