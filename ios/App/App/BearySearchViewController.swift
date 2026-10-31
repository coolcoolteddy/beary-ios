import UIKit
import CoreText

// ===== beary 原生搜索页 =====
// 网页对照：~/workspace/teddy_site/beary.html 内 #searchPage（结构、文案、状态口径）
//   与 .srch-* CSS（尺寸见行内注释）；后端对照：~/workspace/teddy_beary/worker.js
//   GET /beary/api/search（见下方“接口对照”）。
// 容器契约：本页只负责搜索与渲染，不含顶栏/底栏胶囊（容器 SceneDelegate 侧提供，
//   与其他内容页同口径）；点用户只回调 onOpenUser、点日记只回调 onOpenEntry，
//   点返回只回调 onBack，跳转与个人主页打开一律由容器接线，本页不 present、不 push、不碰导航。
// 页结构（网页 #searchPage 同口径）：页顶返回行（返回钮 + “搜索”标题，随内容滚出）
//   + 搜索框（sticky：滚出后贴在安全区顶 6px 处）+ 状态区 / 结果区。
//   （2026-10-29 第 21 项：框下“正在搜索…”行已删；搜索进行时只转框内圈，尾行仅用于失败重试。）
// 分区顺序（网页 renderSrchResults 同口径）：我的日记 · 私密 → 公开日记 → 用户。
// 约束：颜色只用 BearyColors；图标只走 icon_* 资产 + BearyIconImages；
//   不新增 UIGlassEffect，不用 SF Symbol；部署目标 iOS 15.0、Swift 5.0——
//   只用闭包回调，不用 async/await，不用 if-let 简写；无 force unwrap；
//   不用裸 id 变量名（条目标识一律叫 entryId、用户标识一律叫 userId）。

// MARK: - 接口对照（已在 worker.js 核实，BearyAPI.search 已存在，本文件不改接口层）
//
//   GET /beary/api/search?q=
//   - 空 q：服务端直接返回 { users: [], entries: [] }（无 mine 键）。
//   - q 截断到 50 字再 LIKE 匹配（服务端 slice(0, 50)；客户端只 trim，不再截断）。
//   - users：LIMIT 8，按 display_name/handle 匹配；字段 id/display_name/handle/
//     avatar_url（/beary/api/users/:id/avatar?v=N，无头像为 null）/
//     cover_url（有封面才给，无封面为 null）——与现有 SearchUser 模型对齐。
//   - entries：LIMIT 20，仅已公开（publish_at <= now），按 created_at DESC；
//     字段 id/content/images/created_at/author_id/author_name/author_avatar/
//     author_badge（仅 'beta' 才给）/like_count。
//   - mine：仅登录会话返回（未登录为 null），本人全部日记按正文匹配，LIMIT 20；
//     字段 id/content/images/created_at/publish_at/is_public；
//     本页只取其中未公开（is_public != true）的篇目进“我的日记 · 私密”组，
//     与网页 renderSrchResults 的 mine 过滤口径一致；未登录时服务端不给 mine，
//     私密分组自然不出现，不靠客户端登录态再拦一道。
//   - 免登录可搜公开内容：该接口本身不要求会话（无 session 时只缺 mine）。
//   - 回调线程：BearyAPI 回调不在主线程，碰 UI 前必须 DispatchQueue.main.async。

// 113：最近搜索标题行——只扩“清除”热区、不撑高行高：
// BearyHit44Button 的 point(inside:) 已扩到 44，但栈行本身的 hitTest 在点落到
// 行外（与下一行 8pt 间距内）时不会转发；本行重写 point(inside:)/hitTest，
// 把清除钮扩后矩形内的点也认作行内并转发给钮，视觉帧与行高一字不动。
// 行上方的扩出部分仍在父栈 hit 路径之外（容器边界所限），不虚报 44。
final class BearySearchRecentHeaderRow: UIStackView {
    weak var clearButton: UIButton?

    private func expandedClearRect() -> CGRect? {
        guard let button = clearButton else { return nil }
        let dx: CGFloat = button.bounds.width < 44 ? (44 - button.bounds.width) / 2 : 0
        let dy: CGFloat = button.bounds.height < 44 ? (44 - button.bounds.height) / 2 : 0
        return button.frame.insetBy(dx: -dx, dy: -dy)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if super.point(inside: point, with: event) { return true }
        guard let rect = expandedClearRect() else { return false }
        return rect.contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let button = clearButton, let rect = expandedClearRect(), rect.contains(point) {
            let local = convert(point, to: button)
            if button.point(inside: local, with: event) { return button }
        }
        return super.hitTest(point, with: event)
    }
}

final class BearySearchViewController: UIViewController, UITextFieldDelegate, UIScrollViewDelegate {

    // MARK: - 对外 API（容器按此接线，勿改名）

    /// 点返回行：容器负责关闭本页（接线由总协调收尾，本页只留回调）。
    var onBack: (() -> Void)?

    /// 点用户行：传出整条 SearchUser，容器负责打开该用户主页。
    init(onOpenUser: @escaping (SearchUser) -> Void, onOpenEntry: @escaping (String) -> Void) {
        self.onOpenUserHandler = onOpenUser
        self.onOpenEntryHandler = onOpenEntry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 状态

    private let onOpenUserHandler: (SearchUser) -> Void
    private let onOpenEntryHandler: (String) -> Void

    private var searchTimer: Timer?
    /// 顶栏透度批：容器最后一次发来的栏态（本页属性内边距不含安全区顶，见 applyHeaderTopInset）。
    private var headerTopInsetVisible = false
    private var searchFieldToBoxTrailing: NSLayoutConstraint?
    private var searchFieldToClearLeading: NSLayoutConstraint?
    private var boxTopConstraint: NSLayoutConstraint?
    // P2-1：600 列口径（与个人主页 isDesktopColumn 同口径：宽 ≥821 才锁 600，
    // 宽 ≤820 走满宽）——上限约束与满宽约束二选一，见 updateColumnLayout。
    private var contentStackWidthCap: NSLayoutConstraint?
    private var contentStackFullWidth: NSLayoutConstraint?
    private var searchBoxWidthCap: NSLayoutConstraint?
    private var searchBoxFullWidth: NSLayoutConstraint?
    private var searchSeq: Int = 0
    /// S10：在途搜索请求（新搜索先取消上一路；searchSeq 保留作第二道防线）。
    private var currentSearchTask: URLSessionDataTask?
    private var lastQuery: String = ""
    private var showingResults: Bool = false
    private var searchBoxFocused: Bool = false
    // 88 包 M13：结果区底部常驻尾行（对齐时间线/个人主页尾行形态；搜索后端
    // 只返回一批、无分页参数，故尾行只承载加载态与失败重试，不做加载更多）。
    private let searchFooterRow = UIView()
    private let searchFooterRetryButton = BearyButton.retryPill()
    /// Q9 最近搜索：只存本机 UserDefaults，不走服务端；最多 8 条，新在前、去重。
    /// 按账号分桶：登录时键为 bearyRecentSearches_<uid>；未登录时读旧单键
    /// （升级迁移前暂留，登录后迁移见 migrateLegacyRecentSearchesIfNeeded）。
    private let legacyRecentSearchesKey = "bearyRecentSearches"
    private var recentSearchesKey: String {
        if let uid = SessionManager.shared.currentUser?.id {
            return "bearyRecentSearches_\(uid)"
        }
        return legacyRecentSearchesKey
    }

    /// 升级迁移（一次性、幂等）：已登录且旧单键仍有记录时，把旧记录并到
    /// 当前账号桶后（去重、上限 8 条），清旧键；旧记录不擅自删除——合并
    /// 后才清键，桶已有记录时旧记录排在桶记录之后。未登录时不迁移。
    private func migrateLegacyRecentSearchesIfNeeded() {
        guard SessionManager.shared.currentUser?.id != nil else { return }
        let legacy = UserDefaults.standard.stringArray(forKey: legacyRecentSearchesKey) ?? []
        guard !legacy.isEmpty else { return }
        var merged = UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
        for item in legacy where !merged.contains(item) {
            merged.append(item)
        }
        if merged.count > 8 {
            merged = Array(merged.prefix(8))
        }
        UserDefaults.standard.set(merged, forKey: recentSearchesKey)
        UserDefaults.standard.removeObject(forKey: legacyRecentSearchesKey)
    }
    private var recentButtons: [UIButton] = []

    private var userButtons: [UIButton] = []
    private var rowUsers: [SearchUser] = []
    private var entryButtons: [UIButton] = []
    private var rowEntryIds: [String] = []
    /// 5-20：行身份 -> 视图映射（同批动画按 key 查表，不按下标配对）。
    private var entryRowById: [String: UIButton] = [:]
    private var userRowByKey: [String: UIButton] = [:]
    /// 用户行 key 口径与 animateResultRows 的 nextKeys 一致：id 优先，无 id 则 @handle，无两者则无 key。
    private func userKey(for user: SearchUser) -> String? {
        if let userId = user.id {
            return "user:\(userId)"
        } else if let handle = user.handle, !handle.isEmpty {
            return "user:@\(handle)"
        }
        return nil
    }
    // 图片失败重试槽位（用户头像 / 日记首图各一）：随行重建而丢弃，见文件末尾
    // BearySearchImageRetry；clearResultRows 时连同行一起清空。
    private var imageRetryHolders: [BearySearchImageRetry] = []

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let columnWrap = UIView()

    // 页顶返回行：网页 .tl-backrow——返回钮 44 + gap 10 + “搜索”标题 16/700，
    // 上下 padding 0（行高仍 44，图标 24 居中，视觉不变；7-3 约束写法改 44×44）；
    // 返回钮用 beary-back 24 墨（icon_back 资产，网页
    // #srchBack .icon-btn 口径：.icon 24 + .icon-btn ink 色；.tl-acts 的
    // 17px 规则只管 .tl-acts 内按钮，不适用于搜索返回行）。
    private let backRowView = UIView()
    private let backButton = BearyHit44Button(type: .custom)
    private let backTitleLabel = UILabel()

    // 搜索框占位：框体本身是 view 级 sticky 视图，流内留 50 高占位，版式不跳动。
    private let boxPlaceholderView = UIView()

    // 框下预留行：网页 .srch-hint——恒高 24、12.5 灰、gap 6、左右 padding 4，

    // 搜索框：网页 .srch-box——高 50、边框 1.5 line、圆角 999（半高 25）、左右 16、gap 9。
    private let searchBoxView = UIView()
    private let searchIconView = UIImageView()
    private let boxRingView = UIImageView()
    private let searchField = UITextField()
    private let clearButton = BearyHit44Button(type: .custom)

    // 结果区：每次渲染整体重建（与网页 body.innerHTML 重写同口径）。
    private let resultsStack = UIStackView()

    // 状态区：网页 .addr-state——容器 padding 28/20/20；圆 54、图标 25、标题 15、副文案 12.5。
    private let stateWrap = UIView()
    private let stateStack = UIStackView()
    private let stateCircle = UIView()
    private let stateIconView = UIImageView()
    private let stateRingView = UIImageView()
    private let stateTitleLabel = UILabel()
    private let stateSubLabel = UILabel()
    private let retryButton = BearyButton.retryPill()
    /// 8-6：搜索错误重试态改走统一 BearyStateView（标题“搜索失败”+ 副文案 +
    /// 紧凑描边重试钮，动作复用 retryTapped）；其余状态仍走 bespoke stateStack。
    /// errorStateView 放在 errorStateWrap 内（与 stateWrap 同槽位、互斥显隐）：
    /// wrap 作 contentStack 的 arranged subview，隐藏时栈自动塌掉，不用在
    /// stateWrap 内做约束组互换（隐藏视图 + 失活约束易留布局歧义）。
    private let errorStateWrap = UIView()
    private let errorStateView = BearyStateView()
    /// Q5 无结果 CTA：只在无结果态显示，点按复用 clearTapped（清空并回初始态）。
    private let clearSearchButton = UIButton(type: .custom)
    /// Q9 最近搜索容器：插在状态区与结果区之间，只在初始态有记录时显示。
    private let recentWrap = UIView()
    private let recentStack = UIStackView()

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildViews()
        buildConstraints()
        showInitialState()
        // 审计 P2-20：搜索页监听拉黑/举报即时清行并清 quoteCache。
        NotificationCenter.default.addObserver(self, selector: #selector(handleBlockedUserNotification(_:)), name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleReportedEntryNotification(_:)), name: .bearyDidReportEntry, object: nil)
        // 扫荡组 A：键盘弹起时给滚动区补底部留白（见 keyboardWillShow）。
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    /// 扫荡组 A：键盘弹起时滚动区底部留白——此前本页从不监听键盘，
    /// scrollView 底部留白恒为 90，键盘（约 300 高）弹起后会盖住结果区
    /// 末尾几行：不先拖动收键盘就点不到它们。登录页已有同款键盘留白
    /// 处理，本页按同口径补齐（只动 bottom，top 仍由 applyHeaderTopInset 管）。
    private var keyboardBottomInset: CGFloat = 0

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        keyboardBottomInset = max(0, frame.height - view.safeAreaInsets.bottom)
        scrollView.contentInset.bottom = 90 + keyboardBottomInset
        scrollView.scrollIndicatorInsets.bottom = 90 + keyboardBottomInset
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardBottomInset = 0
        scrollView.contentInset.bottom = 90
        scrollView.scrollIndicatorInsets.bottom = 90
    }

    /// 补缺 P2-21：搜索拉黑判定（与 SceneDelegate isBlockedAuthor 同口径：游客不承接拉黑表，
    /// 作者本人永不命中；其余走 BearyBlockedStore 同步缓存，点按路径不发网络）。
    private func isBlockedForSearch(userId: Int?) -> Bool {
        if SessionManager.shared.isGuestMode { return false }
        guard let userId = userId else { return false }
        if let viewerId = SessionManager.shared.currentUser?.id, viewerId == userId { return false }
        return BearyBlockedStore.isBlocked(userId)
    }

    /// 审计 P2-20：拉黑作者——用户行与该作者全部日记行一并清掉，引用缓存同清。
    @objc private func handleBlockedUserNotification(_ note: Notification) {
        guard let userId = note.object as? Int else { return }
        removeBlockedUserFromResults(userId: userId)
    }

    /// 拉黑清行共用路径（广播与点按守卫同走）：从上次渲染数据中摘掉该用户与该作者全部日记行并重渲染。
    private func removeBlockedUserFromResults(userId: Int) {
        guard var data = lastRenderedData, let query = lastRenderedQuery, showingResults else { return }
        var removedIds: [String] = []
        for list in [data.entries, data.mine] {
            for e in list ?? [] where e.authorId == userId {
                if let id = e.id { removedIds.append(id) }
            }
        }
        data.users?.removeAll { $0.id == userId }
        data.entries?.removeAll { $0.authorId == userId }
        data.mine?.removeAll { $0.authorId == userId }
        lastRenderedData = data
        for id in removedIds { BearyDiaryCardCell.quoteCache.removeValue(forKey: id) }
        renderResults(data: data, query: query)
    }

    /// 审计 P2-20：举报日记——公开组与我的组里该篇一并清掉，引用缓存同清。
    @objc private func handleReportedEntryNotification(_ note: Notification) {
        guard let entryId = note.object as? String, !entryId.isEmpty, var data = lastRenderedData, let query = lastRenderedQuery, showingResults else { return }
        data.entries?.removeAll { $0.id == entryId }
        data.mine?.removeAll { $0.id == entryId }
        lastRenderedData = data
        BearyDiaryCardCell.quoteCache.removeValue(forKey: entryId)
        renderResults(data: data, query: query)
    }

    /// 顶栏透度批（容器调用，见 SceneDelegate.applyHeaderTopInsets）：主滚动视图即 scrollView。
    /// 本页滚动框顶锚页安全区（容器页顶改 view.top 后，页安全区顶仍为容器安全区顶，框绝对位置不变），
    /// 故属性内边距只需 60/0：显示 60、收起 0，视觉顶距即安全区顶 + 60 / 安全区顶。
    /// 本页在容器里恒收起，显示值只经容器统一发一次；sticky 框逻辑（safeTop 与占位同移 S）不受影响。
    /// 本页无公开回顶方法、无 contentOffset 在顶判定（容器回顶走 BFS 的 -contentInset.top，收起态为 0）。
    func applyHeaderTopInset(visible: Bool) {
        headerTopInsetVisible = visible
        let top: CGFloat = visible ? 60 : 0
        if scrollView.contentInset.top != top {
            scrollView.contentInset.top = top
            scrollView.scrollIndicatorInsets.top = top
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateColumnLayout()
        updateStickyBoxPosition()
        // 8-11：状态圆圆角走高/2（54 圆 -> 27），不再只靠手写 27；
        // bounds 在首次布局后才定，故此处跟随布局刷新（只动 layer，不改约束）。
        if stateCircle.bounds.height > 0 {
            stateCircle.layer.cornerRadius = stateCircle.bounds.height / 2
        }
        // 旋转/列宽变化后刷新阴影 path（path 与 bounds 绑定，旧 path 会错位）。
        updateSearchBoxShadow()
    }

    /// P2-1：宽 ≥821 时内容列 600 / 搜索框 568 居中，宽 ≤820 时内容列满宽 /
    /// 搜索框 = 屏宽 -32；与个人主页 isDesktopColumn（≥821）同口径，不自创第三种。
    private func updateColumnLayout() {
        let desktop = view.bounds.width >= 821
        contentStackWidthCap?.isActive = desktop
        contentStackFullWidth?.isActive = !desktop
        searchBoxWidthCap?.isActive = desktop
        searchBoxFullWidth?.isActive = !desktop
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateStickyBoxPosition()
    }

    /// sticky 框体吸顶（6-2）：顶约束固定 48（栈顶 4 + 返回行 44，见 1-4），
    /// 吸顶位移只走 transform，滚动回调不再改约束：占位在视野内时框体跟随占位，
    /// 占位滚出后框体贴安全区顶 6px（网页 top:6px）。占位高度 50 不变。
    /// 框体无 transform 时顶在安全区顶 +48 处，故 transform.y = 目标顶距 - 48：
    /// 占位可见时 >= 0（跟随占位），滚出后 -42（贴顶 6）。
    private func updateStickyBoxPosition() {
        let safeTop = view.safeAreaLayoutGuide.layoutFrame.minY
        let placeholderTop = boxPlaceholderView.convert(CGPoint.zero, to: view).y
        let target = max(6, placeholderTop - safeTop)
        searchBoxView.transform = CGAffineTransform(translationX: 0, y: target - 48)
    }

    @objc private func backTapped() {
        onBack?()
    }


    /// U4：仅首次出现聚焦输入框；从详情返回时不再重弹键盘。
    private var searchFieldFocusedOnce = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 网页 openSearch 会在 120ms 后聚焦输入框；原生页打开即聚焦，同口径。
        if !searchFieldFocusedOnce {
            searchFieldFocusedOnce = true
            searchField.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // 64 包反馈修：退出搜索页键盘跟随收走——模态/ push 离开走本回调时先收键盘，
        // 容器 isHidden 切页不触发本回调，另由 SceneDelegate.showPage 离搜索分支收键盘。
        view.endEditing(true)
        // 网页 closeSearch 口径：清防抖计时、序号 +1 使在途请求回包失效。
        searchTimer?.invalidate()
        searchTimer = nil
        searchSeq += 1
    }

    /// 切页生命周期 7 号（最小化）：容器切页只改 isHidden，本回调不触发，
    /// 故容器 showPage 在离页时显式调本钩子，只覆盖序号失效（收键盘已有
    /// showPage 的 view.endEditing，不重复）。
    func pageDidLeave() {
        searchTimer?.invalidate()
        searchTimer = nil
        searchSeq += 1
    }

    deinit {
        searchTimer?.invalidate()
        NotificationCenter.default.removeObserver(self, name: .bearyDidBlockUser, object: nil)
        NotificationCenter.default.removeObserver(self, name: .bearyDidReportEntry, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBorderColors()
    }

    // MARK: - 搭建

    private func buildViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .onDrag
        scrollView.delegate = self
        // 底留白 90：与 Feed/时间线/消息同口径，末行不再被底栏胶囊盖住。
        scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 90, right: 0)
        scrollView.scrollIndicatorInsets = scrollView.contentInset
        view.addSubview(scrollView)

        columnWrap.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(columnWrap)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        // 列内边距 16 由 stack layoutMargins 承担（网页 #searchPage .pf-col padding 16
        // 同口径）：列本身不再收窄，见 buildConstraints。
        contentStack.isLayoutMarginsRelativeArrangement = true
        contentStack.layoutMargins = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        columnWrap.addSubview(contentStack)

        // 页顶返回行（流内，随内容滚出；框体 sticky 后它已滚出视野）。
        backRowView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(backRowView)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        backButton.tintColor = BearyColors.ink
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backButton.bearyAddPressFeedback()
        backRowView.addSubview(backButton)

        backTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        backTitleLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 16))
        backTitleLabel.adjustsFontForContentSizeCategory = true
        backTitleLabel.textColor = BearyColors.ink
        backTitleLabel.text = "搜索"
        backRowView.addSubview(backTitleLabel)

        // 搜索框占位（流内 50 高）。
        boxPlaceholderView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(boxPlaceholderView)

        // 搜索框：view 级视图（sticky 用，见 updateStickyBoxPosition），
        // 后于 scrollView 加入视图层级，滚动内容从它下方滑过时被盖住。
        searchBoxView.translatesAutoresizingMaskIntoConstraints = false
        searchBoxView.backgroundColor = BearyColors.bg
        searchBoxView.layer.borderWidth = 1.5
        searchBoxView.layer.cornerRadius = 25
        // 阴影须画出框外，masksToBounds 必须关；框内元素均有内边距，不会溢出圆角。
        searchBoxView.layer.masksToBounds = false
        view.addSubview(searchBoxView)

        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchIconView.image = BearyIconImages.image(named: "icon_search", pointSize: 21)
        searchIconView.tintColor = BearyColors.gray
        searchIconView.contentMode = .scaleAspectFit
        searchBoxView.addSubview(searchIconView)

        boxRingView.translatesAutoresizingMaskIntoConstraints = false
        boxRingView.image = BearyIconImages.image(named: "icon_refresh", pointSize: 21)
        boxRingView.tintColor = BearyColors.gray
        boxRingView.contentMode = .scaleAspectFit
        boxRingView.isHidden = true
        searchBoxView.addSubview(boxRingView)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16))
        searchField.adjustsFontForContentSizeCategory = true
        searchField.textColor = BearyColors.ink
        // 占位色走 BearyColors.gray（与登录/邀请页 attributedPlaceholder 同口径）。
        searchField.attributedPlaceholder = NSAttributedString(string: "搜索日记或用户", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 16)),
        ])
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchFieldChanged), for: .editingChanged)
        searchBoxView.addSubview(searchField)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        // 112：帧本身扩到 44×44（见约束处），淡底圆不再由按钮底色画满帧，
        // 改内嵌 26×26 居中圆视图：视觉圆心/半径与原来完全一致，图标仍 13pt 居中。
        // 按钮底透明，BearyHit44Button 的 point(inside:) 扩区此时已是冗余兜底（帧已 44）。
        clearButton.backgroundColor = UIColor.clear
        let clearVisual = UIView()
        clearVisual.translatesAutoresizingMaskIntoConstraints = false
        clearVisual.backgroundColor = BearyColors.faint
        clearVisual.layer.cornerRadius = 13
        clearVisual.clipsToBounds = true
        clearVisual.isUserInteractionEnabled = false
        clearButton.addSubview(clearVisual)
        NSLayoutConstraint.activate([
            clearVisual.centerXAnchor.constraint(equalTo: clearButton.centerXAnchor),
            clearVisual.centerYAnchor.constraint(equalTo: clearButton.centerYAnchor),
            clearVisual.widthAnchor.constraint(equalToConstant: 26),
            clearVisual.heightAnchor.constraint(equalToConstant: 26),
        ])
        clearButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 13), for: .normal)
        clearButton.tintColor = BearyColors.gray
        clearButton.isHidden = true
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clearButton.bearyAddPressFeedback()
        searchBoxView.addSubview(clearButton)

        // 状态区（初始/加载/无结果/失败四态共用一处容器，互斥显示）
        stateWrap.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(stateWrap)

        stateStack.translatesAutoresizingMaskIntoConstraints = false
        stateStack.axis = .vertical
        stateStack.alignment = .center
        stateStack.spacing = 0
        stateWrap.addSubview(stateStack)

        stateCircle.translatesAutoresizingMaskIntoConstraints = false
        // 网页 .addr-stic：橙 18% 混 surface（不是 18% 透明盖在 bg 上；
        // 深色下 bg 纯黑、surface #26262c，两者差一档）。
        stateCircle.backgroundColor = BearySearchViewController.mixedColor(BearyColors.orange, 0.18, over: BearyColors.surface)
        stateCircle.layer.borderWidth = 1
        // 8-11：初值 27 = 54/2（首次布局前 bounds 未定时的正确帧；布局后由
        // viewDidLayoutSubviews 按高/2 重算，见该处注释）。
        stateCircle.layer.cornerRadius = 27
        stateCircle.layer.masksToBounds = true
        stateStack.addArrangedSubview(stateCircle)

        stateIconView.translatesAutoresizingMaskIntoConstraints = false
        // 8-12 例外：状态圆内图标 25 不归 21 档——它是 54 圆的圆内比例，
        // 统一组件 BearyStateView 同款 54 圆亦用 25，故保留。
        stateIconView.image = BearyIconImages.image(named: "icon_search", pointSize: 25)
        stateIconView.tintColor = BearyColors.orange
        stateIconView.contentMode = .scaleAspectFit
        stateCircle.addSubview(stateIconView)

        stateRingView.translatesAutoresizingMaskIntoConstraints = false
        stateRingView.image = BearyIconImages.image(named: "icon_refresh", pointSize: 25)
        stateRingView.tintColor = BearyColors.gray
        stateRingView.contentMode = .scaleAspectFit
        stateRingView.isHidden = true
        stateCircle.addSubview(stateRingView)

        stateTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        stateTitleLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 15))
        stateTitleLabel.adjustsFontForContentSizeCategory = true
        stateTitleLabel.textColor = BearyColors.ink
        stateTitleLabel.textAlignment = .center
        stateTitleLabel.numberOfLines = 0
        stateTitleLabel.lineBreakMode = .byCharWrapping
        stateStack.addArrangedSubview(stateTitleLabel)

        stateSubLabel.translatesAutoresizingMaskIntoConstraints = false
        stateSubLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 12.5))
        stateSubLabel.adjustsFontForContentSizeCategory = true
        stateSubLabel.textColor = BearyColors.gray
        stateSubLabel.textAlignment = .center
        stateSubLabel.numberOfLines = 0
        stateSubLabel.lineBreakMode = .byCharWrapping
        stateStack.addArrangedSubview(stateSubLabel)

        // 失败重试：审计 P2——重试类描边 pill 收敛为 BearyButton 工厂唯一档（紧凑款 36 高），
        // 不再各写一套尺寸；左右内边距 20 保留原网页 .addr-retry 口径。
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        retryButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.compact).height).isActive = true
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.bearyAddPressFeedback()
        stateStack.addArrangedSubview(retryButton)

        // Q5 无结果 CTA：pill 口径（高 44、圆角 22、左右内边距 20），默认隐藏，
        // 只由 showState(showClear: true) 在无结果态亮起；动作复用 clearTapped。
        clearSearchButton.translatesAutoresizingMaskIntoConstraints = false
        clearSearchButton.setTitle("清空搜索", for: .normal)
        clearSearchButton.setTitleColor(BearyColors.ink, for: .normal)
        clearSearchButton.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 14, weight: .semibold))
        clearSearchButton.titleLabel?.adjustsFontForContentSizeCategory = true
        clearSearchButton.backgroundColor = BearyColors.surface
        clearSearchButton.layer.borderWidth = 1
        clearSearchButton.layer.bearyDynamicBorderColor = BearyColors.line
        clearSearchButton.layer.cornerRadius = 22
        clearSearchButton.layer.masksToBounds = true
        clearSearchButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        clearSearchButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        clearSearchButton.isHidden = true
        clearSearchButton.addTarget(self, action: #selector(clearSearchTapped), for: .touchUpInside)
        clearSearchButton.bearyAddPressFeedback()
        stateStack.addArrangedSubview(clearSearchButton)

        // 8-6：错误态 BearyStateView（wrap 与 stateWrap 同槽位、互斥显隐；
        // 内边距 28/20/20 与 bespoke stateStack 同口径，切换只在 showState /
        // showFailedState 做显隐，不在滚动回调里动约束）。
        errorStateWrap.translatesAutoresizingMaskIntoConstraints = false
        errorStateWrap.isHidden = true
        contentStack.addArrangedSubview(errorStateWrap)
        errorStateView.translatesAutoresizingMaskIntoConstraints = false
        errorStateView.configure(kind: .error, title: "搜索失败", subtitle: "网络好像不太顺", iconName: "icon_search", actionTitle: "重试", onAction: { [weak self] in self?.retryTapped() })
        errorStateWrap.addSubview(errorStateView)
        NSLayoutConstraint.activate([
            errorStateView.topAnchor.constraint(equalTo: errorStateWrap.topAnchor, constant: 28),
            errorStateView.leadingAnchor.constraint(equalTo: errorStateWrap.leadingAnchor, constant: 20),
            errorStateView.trailingAnchor.constraint(equalTo: errorStateWrap.trailingAnchor, constant: -20),
            errorStateView.bottomAnchor.constraint(equalTo: errorStateWrap.bottomAnchor, constant: -20),
        ])

        // Q9 最近搜索区：标题 + 本机记录行（行高 44、圆角 14 卡片口径）；
        // 内容由 renderRecentSearches 重建，初始态外一律隐藏（见 showState）。
        recentWrap.translatesAutoresizingMaskIntoConstraints = false
        recentWrap.isHidden = true
        contentStack.addArrangedSubview(recentWrap)
        recentStack.translatesAutoresizingMaskIntoConstraints = false
        recentStack.axis = .vertical
        recentStack.spacing = 8
        recentWrap.addSubview(recentStack)
        NSLayoutConstraint.activate([
            recentStack.topAnchor.constraint(equalTo: recentWrap.topAnchor),
            recentStack.bottomAnchor.constraint(equalTo: recentWrap.bottomAnchor),
            recentStack.leadingAnchor.constraint(equalTo: recentWrap.leadingAnchor),
            recentStack.trailingAnchor.constraint(equalTo: recentWrap.trailingAnchor),
        ])

        // 结果区
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        resultsStack.axis = .vertical
        resultsStack.spacing = 0
        contentStack.addArrangedSubview(resultsStack)

        // 88 包 M13：结果区尾行（加载态转圈＋失败重试），平时隐藏；高度 44
        // 与时间线尾行同口径，内容居中，避免显隐两态约束冲突。
        searchFooterRow.translatesAutoresizingMaskIntoConstraints = false
        searchFooterRow.isHidden = true
        contentStack.addArrangedSubview(searchFooterRow)
        // 审计 P2：与失败态重试钮同为 BearyButton 工厂紧凑档，不再各写一套尺寸。
        searchFooterRetryButton.translatesAutoresizingMaskIntoConstraints = false
        searchFooterRetryButton.setTitle("重试", for: .normal)
        searchFooterRetryButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        searchFooterRetryButton.heightAnchor.constraint(equalToConstant: BearyButtonStyle.secondaryOutline(.compact).height).isActive = true
        searchFooterRetryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        searchFooterRetryButton.bearyAddPressFeedback()
        searchFooterRow.addSubview(searchFooterRetryButton)
        NSLayoutConstraint.activate([
            searchFooterRow.heightAnchor.constraint(equalToConstant: 44),
            searchFooterRetryButton.centerXAnchor.constraint(equalTo: searchFooterRow.centerXAnchor),
            searchFooterRetryButton.centerYAnchor.constraint(equalTo: searchFooterRow.centerYAnchor),
        ])

        updateBorderColors()
    }

    private func buildConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // 内容列（P2-1）：宽 ≥821 时 600 居中、宽 ≤820 时满宽（见 updateColumnLayout）；
            // 16 边距改由 contentStack layoutMargins 承担（窄屏仍是 16）。
            columnWrap.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            columnWrap.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            columnWrap.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            columnWrap.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            columnWrap.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: columnWrap.topAnchor, constant: 4),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: columnWrap.leadingAnchor, constant: 0),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: columnWrap.trailingAnchor, constant: 0),
            contentStack.centerXAnchor.constraint(equalTo: columnWrap.centerXAnchor),
            contentStack.bottomAnchor.constraint(equalTo: columnWrap.bottomAnchor),

            // 页顶返回行：按钮 44 + gap 10 + 标题，上下 padding 0（行高仍 44，图标 24 居中，视觉不变）。
            backButton.leadingAnchor.constraint(equalTo: backRowView.leadingAnchor),
            backButton.topAnchor.constraint(equalTo: backRowView.topAnchor, constant: 0),
            backButton.bottomAnchor.constraint(equalTo: backRowView.bottomAnchor, constant: 0),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            backTitleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 10),
            backTitleLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            backTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: backRowView.trailingAnchor),

            boxPlaceholderView.heightAnchor.constraint(equalToConstant: 50),


            // sticky 框体：与列内容同宽（16 边距 + ≤568 居中），顶距固定 48、吸顶位移走 transform。
            searchBoxView.heightAnchor.constraint(equalToConstant: 50),
            searchBoxView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            searchBoxView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            searchBoxView.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            searchIconView.leadingAnchor.constraint(equalTo: searchBoxView.leadingAnchor, constant: 16),
            searchIconView.centerYAnchor.constraint(equalTo: searchBoxView.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 21),
            searchIconView.heightAnchor.constraint(equalToConstant: 21),

            boxRingView.leadingAnchor.constraint(equalTo: searchBoxView.leadingAnchor, constant: 16),
            boxRingView.centerYAnchor.constraint(equalTo: searchBoxView.centerYAnchor),
            boxRingView.widthAnchor.constraint(equalToConstant: 21),
            boxRingView.heightAnchor.constraint(equalToConstant: 21),

            searchField.leadingAnchor.constraint(equalTo: searchBoxView.leadingAnchor, constant: 44),
            searchField.topAnchor.constraint(equalTo: searchBoxView.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchBoxView.bottomAnchor),

            // 112：清空钮热区帧本身 44×44。视觉圆心须与原来一致：
            // 原 trailing -12、宽 26，圆心在框右 -25；现 trailing -3、宽 44，
            // 圆心仍在 -25（-3-22），内嵌 26 圆与 13pt 图标均居中，视觉不动。
            clearButton.trailingAnchor.constraint(equalTo: searchBoxView.trailingAnchor, constant: -3),
            clearButton.centerYAnchor.constraint(equalTo: searchBoxView.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 44),
            clearButton.heightAnchor.constraint(equalToConstant: 44),

            stateStack.topAnchor.constraint(equalTo: stateWrap.topAnchor, constant: 28),
            stateStack.leadingAnchor.constraint(equalTo: stateWrap.leadingAnchor, constant: 20),
            stateStack.trailingAnchor.constraint(equalTo: stateWrap.trailingAnchor, constant: -20),
            stateStack.bottomAnchor.constraint(equalTo: stateWrap.bottomAnchor, constant: -20),

            stateCircle.widthAnchor.constraint(equalToConstant: 54),
            stateCircle.heightAnchor.constraint(equalToConstant: 54),

            stateIconView.centerXAnchor.constraint(equalTo: stateCircle.centerXAnchor),
            stateIconView.centerYAnchor.constraint(equalTo: stateCircle.centerYAnchor),
            stateIconView.widthAnchor.constraint(equalToConstant: 25),
            stateIconView.heightAnchor.constraint(equalToConstant: 25),

            stateRingView.centerXAnchor.constraint(equalTo: stateCircle.centerXAnchor),
            stateRingView.centerYAnchor.constraint(equalTo: stateCircle.centerYAnchor),
            stateRingView.widthAnchor.constraint(equalToConstant: 25),
            stateRingView.heightAnchor.constraint(equalToConstant: 25),
        ])
        // P2-1：列宽二选一约束（初始按桌面态建，viewDidLayoutSubviews 的
        // updateColumnLayout 按实际宽度纠正；窄屏满宽约束与上限约束永不同时激活）。
        contentStackWidthCap = contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        contentStackWidthCap?.isActive = true
        contentStackFullWidth = contentStack.widthAnchor.constraint(equalTo: columnWrap.widthAnchor)
        contentStackFullWidth?.isActive = false
        searchBoxWidthCap = searchBoxView.widthAnchor.constraint(lessThanOrEqualToConstant: 568)
        searchBoxWidthCap?.isActive = true
        searchBoxFullWidth = searchBoxView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        searchBoxFullWidth?.isActive = false
        // sticky 框体顶距固定 48（1-4：栈顶 4 + 返回行 44）；吸顶位移走 transform，约束此后不再改动。
        boxTopConstraint = searchBoxView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 48)
        boxTopConstraint?.isActive = true
        // 输入框右缘：清空钮显示时贴清空钮、无清空钮时贴框右 16（两条约束互斥切换）。
        searchFieldToBoxTrailing = searchField.trailingAnchor.constraint(equalTo: searchBoxView.trailingAnchor, constant: -16)
        // 112：输入框右缘到清空钮视觉圆左缘仍留 8pt。钮帧已扩到 44，
        // 视觉圆左缘 = 帧左缘 + 9（(44-26)/2），故此处常量由 -8 改为 +1；
        // 换算回框右：原 -38-8 = -46，现 -47+1 = -46，输入框宽度原样不变。
        searchFieldToClearLeading = searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: 1)
        searchFieldToBoxTrailing?.isActive = true
        searchFieldToClearLeading?.isActive = false
        // 标题与副文案间距：网页 .addr-state b margin-bottom 4；圆到底部文案间距 11。
        stateStack.setCustomSpacing(11, after: stateCircle)
        stateStack.setCustomSpacing(4, after: stateTitleLabel)
        stateStack.setCustomSpacing(10, after: stateSubLabel)
    }

    /// CGColor 不跟随深浅模式自动变：边框色一律这里集中刷新。
    private func updateBorderColors() {
        if searchBoxFocused {
            // 网页 :focus-within 口径：边框取蓝 55% 混 line（color-mix，
            // 不是蓝 55% 透明——深色下两者不同；原 withAlphaComponent 写法
            // 在深色 line #3a3a40 上会偏蓝偏暗，随 E-G11 一并纠正）。
            // 边框色由 traitCollectionDidChange → updateBorderColors 重赋。
            searchBoxView.layer.bearyDynamicBorderColor = BearySearchViewController.mixedColor(BearyColors.blue, 0.55, over: BearyColors.line)
        } else {
            searchBoxView.layer.bearyDynamicBorderColor = BearyColors.line
        }
        // 状态圆描边：网页 inset 1px 橙 25% 圈。
        stateCircle.layer.bearyDynamicBorderColor = BearyColors.orange.withAlphaComponent(0.25)
        retryButton.layer.bearyDynamicBorderColor = BearyColors.line
        clearSearchButton.layer.bearyDynamicBorderColor = BearyColors.line
        searchFooterRetryButton.layer.bearyDynamicBorderColor = BearyColors.line
        updateSearchBoxShadow()
    }

    /// 网页 color-mix(in srgb, A w%, B) 的原生等价：按当前 trait 重解两色
    /// 再按权重混 RGBA（BearyColors.alpha 只降透明度，混不出“盖在某色上”
    /// 的效果；动态色闭包保证深浅切换后重解，不固化当前 trait）。
    /// 本文件内专用（不改共享 BearyNativeCommon，避免波及其他路）。
    private static func mixedColor(_ first: UIColor, _ weight: CGFloat, over second: UIColor) -> UIColor {
        return UIColor { trait in
            let a = rgbComponents(of: first.resolvedColor(with: trait))
            let b = rgbComponents(of: second.resolvedColor(with: trait))
            return UIColor(
                red: a.0 * weight + b.0 * (1 - weight),
                green: a.1 * weight + b.1 * (1 - weight),
                blue: a.2 * weight + b.2 * (1 - weight),
                alpha: a.3 * weight + b.3 * (1 - weight)
            )
        }
    }

    private static func rgbComponents(of color: UIColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return (r, g, b, a)
        }
        var w: CGFloat = 0
        if color.getWhite(&w, alpha: &a) {
            return (w, w, w, a)
        }
        return (0, 0, 0, 1)
    }

    /// 搜索框阴影（网页 .srch-box）：常态 0 4 14 黑 5%；聚焦时常态阴影
    /// 被 :focus-within 的 2px 蓝 55% 外圈取代（不是叠加）。外圈用
    /// radius 0 + 外扩 2px 的 shadowPath 实现实心环：框体不透明底盖住
    /// path 内部，只露出框外 2px 一圈；path 随 bounds 更新（见
    /// viewDidLayoutSubviews），旋转后不错位。
    private func updateSearchBoxShadow() {
        let bounds = searchBoxView.bounds
        guard bounds.width > 0 && bounds.height > 0 else { return }
        if searchBoxFocused {
            let ring = BearySearchViewController.mixedColor(BearyColors.blue, 0.55, over: BearyColors.line)
            searchBoxView.layer.shadowColor = ring.cgColor
            searchBoxView.layer.shadowOpacity = 1
            searchBoxView.layer.shadowOffset = CGSize.zero
            searchBoxView.layer.shadowRadius = 0
            searchBoxView.layer.shadowPath = UIBezierPath(
                roundedRect: bounds.insetBy(dx: -2, dy: -2),
                cornerRadius: 27
            ).cgPath
        } else {
            searchBoxView.layer.shadowColor = UIColor.black.cgColor
            searchBoxView.layer.shadowOpacity = 0.05
            searchBoxView.layer.shadowOffset = CGSize(width: 0, height: 4)
            searchBoxView.layer.shadowRadius = 14
            searchBoxView.layer.shadowPath = UIBezierPath(
                roundedRect: bounds,
                cornerRadius: 25
            ).cgPath
        }
    }

    // MARK: - 输入与搜索

    /// 清空钮显隐与输入框右缘约束同步切换。
    private func updateClearButtonVisibility() {
        let showClear = !(searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        clearButton.isHidden = !showClear
        searchFieldToBoxTrailing?.isActive = !showClear
        searchFieldToClearLeading?.isActive = showClear
    }

    @objc private func searchFieldChanged() {
        updateClearButtonVisibility()
        searchTimer?.invalidate()
        // 网页 input 监听口径：250ms 防抖后执行。
        searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.runSearch(query: self.searchField.text ?? "")
        }
    }

    @objc private func clearTapped() {
        searchField.text = ""
        updateClearButtonVisibility()
        searchTimer?.invalidate()
        runSearch(query: "")
        searchField.becomeFirstResponder()
    }

    @objc private func retryTapped() {
        // 网页失败态重试口径：立即重跑上一次关键词，不走防抖。
        runSearch(query: lastQuery)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        searchTimer?.invalidate()
        runSearch(query: textField.text ?? "")
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        searchBoxFocused = true
        updateBorderColors()
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        searchBoxFocused = false
        updateBorderColors()
    }

    private func runSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        lastQuery = trimmed
        // 序号防旧请求：每次执行序号 +1，在途回包凭序号失效（与网页 srchSeq 同口径）。
        searchSeq += 1
        let seq = searchSeq
        // S10：先取消上一路在途请求，旧回包由序号守卫丢弃。
        currentSearchTask?.cancel()
        currentSearchTask = nil
        if trimmed.isEmpty {
            setBoxBusy(false)
            showInitialState()
            return
        }
        // 网页口径：已有结果时保持结果区、框内圈转（2026-10-29 第 21 项：框下“正在搜索…”行已删，搜索进行时不再显示尾行）；
        // 无结果时结果区改加载态（含登录提示）。
        if showingResults {
            setBoxBusy(true)
            // 109：新一轮搜索开始即清失败尾行（setSearchFooter 注释口径：搜索进行时
            // 不显示尾行，只转框内圈）；失败回包仍可经 showFailedStateKeepingResults 再亮。
            // 旧回包另有 searchSeq 序号守卫，不会把旧失败亮回新一轮。
            setSearchFooter(failed: false)
        } else {
            showLoadingState()
        }
        currentSearchTask = BearyAPI.shared.search(q: trimmed) { [weak self] result in
            // BearyAPI 回调不在主线程，碰 UI 必须回主线程。
            DispatchQueue.main.async {
                guard let self = self else { return }
                if seq != self.searchSeq { return }
                self.setBoxBusy(false)
                switch result {
                case .success(let data):
                    self.recordRecentSearch(trimmed)
                    self.renderResults(data: data, query: trimmed)
                case .failure:
                    // S7：已有旧结果时不进失败态（showState 会清结果区），
                    // 只在结果区行内补重试入口，旧结果行原样保留；
                    // 无旧结果时才进现有失败态。searchSeq 序号守卫在上不动。
                    if self.showingResults {
                        self.showFailedStateKeepingResults()
                    } else {
                        self.showFailedState()
                    }
                }
            }
        }
    }

    /// 框内圈：加载时以转圈替换放大镜（网页 srchSetIconBusy 同款语义）。
    /// （2026-10-29 第 21 项：框下“正在搜索…”行已删，只留框内圈；尾行仅用于失败重试。）
    private func setBoxBusy(_ busy: Bool) {
        searchIconView.isHidden = busy
        boxRingView.isHidden = !busy
        if busy {
            BearyIconMotion.startSpin(on: boxRingView, duration: 0.9, key: "bearyBoxSpin")
        } else {
            BearyIconMotion.stopSpin(on: boxRingView, key: "bearyBoxSpin")
        }
    }

    // MARK: - 状态渲染（网页 srchStateHtml 四态口径）

    private func showState(title: String?, sub: String?, showRetry: Bool, loading: Bool, showClear: Bool = false) {
        // 8-6：非错误态一律藏起错误 wrap（stack arranged subview，隐藏即塌掉）。
        errorStateWrap.isHidden = true
        errorStateWrap.alpha = 1
        let wasStateHidden = stateWrap.isHidden
        showingResults = false
        resultsStack.isHidden = true
        setSearchFooter(failed: false)
        // Q9：最近搜索只属于初始态，其他状态一律隐藏（初始态由 showInitialState 重亮）。
        recentWrap.isHidden = true
        clearResultRows()
        stateWrap.isHidden = false
        stateTitleLabel.text = title
        stateTitleLabel.isHidden = (title == nil)
        stateSubLabel.text = sub
        stateSubLabel.isHidden = (sub == nil)
        retryButton.isHidden = !showRetry
        clearSearchButton.isHidden = !showClear
        stateIconView.isHidden = loading
        stateRingView.isHidden = !loading
        if loading {
            BearyIconMotion.startSpin(on: stateRingView, duration: 1, key: "bearyStateSpin")
        } else {
            BearyIconMotion.stopSpin(on: stateRingView, key: "bearyStateSpin")
        }
        // 新规矩 (b)：状态区首次出现淡入（同态内文案更换不重播；减动效直显）。
        if wasStateHidden && !UIAccessibility.isReduceMotionEnabled {
            stateWrap.alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                self.stateWrap.alpha = 1
            })
        } else {
            stateWrap.alpha = 1
        }
    }

    private func showInitialState() {
        // 网页 init 态：放大镜圆 + 仅登录态一句“你的私密日记只有你自己能搜到”。
        let sub: String?
        if SessionManager.shared.isLoggedIn {
            sub = "你的私密日记只有你自己能搜到"
        } else {
            sub = nil
        }
        showState(title: nil, sub: sub, showRetry: false, loading: false)
        // Q9：初始态补最近搜索（无记录时整区隐藏）。
        renderRecentSearches()
    }

    /// Q9 最近搜索：读本机记录，重建标题 + 行；点行直接搜（不走服务端）。
    private func loadRecentSearches() -> [String] {
        migrateLegacyRecentSearchesIfNeeded()
        return UserDefaults.standard.stringArray(forKey: recentSearchesKey) ?? []
    }

    private func recordRecentSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        var list = loadRecentSearches().filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        if list.count > 8 {
            list = Array(list.prefix(8))
        }
        UserDefaults.standard.set(list, forKey: recentSearchesKey)
    }

    private func renderRecentSearches() {
        for view in recentStack.arrangedSubviews {
            recentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        recentButtons = []
        let terms = loadRecentSearches()
        if terms.isEmpty {
            recentWrap.isHidden = true
            return
        }
        let titleLabel = UILabel()
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "最近搜索"
        titleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = BearyColors.gray
        // A7：一键清除入口（标题行右侧弱化文字钮；只清当前账号桶记录，
        // 记录机制与 8 条上限不动；清除后同步重建本区，无记录时整区隐藏）。
        // 113：钮改 BearyHit44Button（视觉帧不动，热区扩到 44）+ 标题行用
        // BearySearchRecentHeaderRow 转发扩后热区，行高不撑高。
        let clearButton = BearyHit44Button(type: .system)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setTitle("清除", for: .normal)
        clearButton.titleLabel?.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        clearButton.titleLabel?.adjustsFontForContentSizeCategory = true
        clearButton.setTitleColor(BearyColors.gray, for: .normal)
        clearButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        clearButton.addTarget(self, action: #selector(clearRecentSearchesTapped), for: .touchUpInside)
        clearButton.bearyAddPressFeedback()
        clearButton.accessibilityLabel = "清除最近搜索"
        let headerSpacer = UIView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = BearySearchRecentHeaderRow(arrangedSubviews: [titleLabel, headerSpacer, clearButton])
        headerRow.clearButton = clearButton
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.axis = .horizontal
        headerRow.alignment = .center
        recentStack.addArrangedSubview(headerRow)
        for term in terms {
            let button = UIButton(type: .custom)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitle(term, for: .normal)
            button.setTitleColor(BearyColors.ink, for: .normal)
            button.titleLabel?.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 15))
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.backgroundColor = BearyColors.surface
            button.layer.cornerRadius = 14
            button.layer.masksToBounds = true
            button.contentHorizontalAlignment = .left
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.accessibilityLabel = "搜索" + term
            button.addTarget(self, action: #selector(recentSearchTapped(_:)), for: .touchUpInside)
            button.bearyAddPressFeedback()
            recentStack.addArrangedSubview(button)
            recentButtons.append(button)
        }
        recentWrap.isHidden = false
        if !UIAccessibility.isReduceMotionEnabled {
            recentWrap.alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                self.recentWrap.alpha = 1
            })
        } else {
            recentWrap.alpha = 1
        }
    }

    @objc private func recentSearchTapped(_ sender: UIButton) {
        guard let term = sender.title(for: .normal), !term.isEmpty else { return }
        searchField.text = term
        updateClearButtonVisibility()
        searchTimer?.invalidate()
        runSearch(query: term)
    }

    /// A7：一键清除最近搜索（当前账号桶；未登录时即旧单键），随后同步重建本区。
    @objc private func clearRecentSearchesTapped() {
        UserDefaults.standard.removeObject(forKey: recentSearchesKey)
        renderRecentSearches()
    }

    @objc private func clearSearchTapped() {
        // Q5 无结果 CTA：复用框内清空逻辑（清空输入、回初始态并亮起最近搜索）。
        clearTapped()
    }

    private func showLoadingState() {
        // 加载态：圆内转圈 + 登录态一句“你的私密日记只有你自己能搜到”
        // （网页 srchStateHtml('loading') 同口径）。
        let sub: String?
        if SessionManager.shared.isLoggedIn {
            sub = "你的私密日记只有你自己能搜到"
        } else {
            sub = nil
        }
        showState(title: nil, sub: sub, showRetry: false, loading: true)
    }

    private func showFailedState() {
        // 8-6：无旧结果的失败态改走统一 BearyStateView（文案与重试动作不变，
        // 仍是标题“搜索失败”+ 副文案“网络好像不太顺”+ 重试钮走 retryTapped）；
        // 有旧结果的失败仍走结果区尾行重试（showFailedStateKeepingResults），不动。
        let wasErrorHidden = errorStateWrap.isHidden
        showingResults = false
        resultsStack.isHidden = true
        setSearchFooter(failed: false)
        recentWrap.isHidden = true
        clearResultRows()
        stateWrap.isHidden = true
        errorStateWrap.isHidden = false
        // 新规矩 (b) 同口径：错误态首次出现淡入（同态内不重播；减动效直显）。
        if wasErrorHidden && !UIAccessibility.isReduceMotionEnabled {
            errorStateWrap.alpha = 0
            UIView.animate(withDuration: 0.2, animations: {
                self.errorStateWrap.alpha = 1
            })
        } else {
            errorStateWrap.alpha = 1
        }
    }

    /// S7：有旧结果时的失败处理——不调 showState（它会清结果区），
    /// 旧结果行原样保留，失败重试改走结果区尾行。
    /// 样式与动作复用失败态 retryButton（工厂紧凑描边 pill：标题“重试”/
    /// 36 高/圆角 18/14 semibold/surface 底/1 line 边框，点按走同一 retryTapped 立即重跑
    /// lastQuery，不走防抖。成功/清状态时尾行隐藏。
    private func showFailedStateKeepingResults() {
        showingResults = true
        stateWrap.isHidden = true
        // 8-6 不变量：错误 wrap 只在 showFailedState 可见，其余路径一律藏起。
        errorStateWrap.isHidden = true
        // 结果出现时最近搜索区隐藏（只属于初始态）。
        recentWrap.isHidden = true
        resultsStack.isHidden = false
        // 88 包 M13：失败重试改走结果区尾行（原行内重试行已并入尾行）。
        setSearchFooter(failed: true)
    }

    /// 尾行两态（失败重试／隐藏），与时间线/个人主页尾行同形态；搜索进行时不显示尾行（只转框内圈）。
    private func setSearchFooter(failed: Bool) {
        if failed {
            searchFooterRow.isHidden = false
            searchFooterRetryButton.isHidden = false
        } else {
            searchFooterRow.isHidden = true
        }
    }

    private func showNoneState(query: String) {
        // 网页 none 态：标题“没有找到「q」”+ 副文案“换个关键词试试”+ Q5 清空搜索 CTA。
        showState(title: "没有找到「" + query + "」", sub: "换个关键词试试", showRetry: false, loading: false, showClear: true)
    }

    // MARK: - 结果渲染

    private func clearResultRows() {
        for view in resultsStack.arrangedSubviews {
            resultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        userButtons = []
        rowUsers = []
        entryButtons = []
        rowEntryIds = []
        entryRowById = [:]
        userRowByKey = [:]
        imageRetryHolders = []
        // 88 包 M13：尾行不属于结果区，随结果区重建而隐藏（成功重渲末尾亦会隐藏）。
        setSearchFooter(failed: false)
    }

    /// 审计 P2-20：最近一次成功渲染的原始结果（供拉黑/举报广播过滤后重渲；重渲走
    /// 同 query 的 lastResultRowKeys，行入场不重播）。
    private var lastRenderedData: SearchResult?
    private var lastRenderedQuery: String?

    private func renderResults(data: SearchResult, query: String) {
        lastRenderedData = data
        lastRenderedQuery = query
        // 补缺 P3-40：我的组只取确认为私密篇（is_public == false）；缺失字段（nil）不进私密组
        //（服务端对 mine 下发 is_public，未下发时不按私密误标；原 != true 把缺失也划进私密组）。
        var mineEntries: [Entry] = []
        if let mine = data.mine {
            for entry in mine {
                if entry.isPublic == false {
                    mineEntries.append(entry)
                }
            }
        }
        // 64 包回归修：公开组直接用服务端 entries——服务端 SQL 已按 published=1 过滤，
        // 且公开条目不下发 is_public 字段（2026-10-26 curl 实测 /beary/api/search?q=的 返回
        // entries 均无 is_public）；旧的 isPublic == true 二次过滤把全部公开条目滤掉，
        // 导致公开组恒空。我的组保留 is_public 过滤（服务端对 mine 下发 is_public）。
        // 审计 P0-3 核实：服务端搜索 SQL 已含 ephemeral_until > now 条件（worker.js
        // 搜索段）与拉黑过滤，故后端无需补；App 侧再加一道有效态过滤作防御
        // （时钟/缓存边缘下过期限时篇也不进公开组）。
        let publicEntries = (data.entries ?? []).filter { BearyEphemeral.isEffectivelyPublic($0) }.filter { !isBlockedForSearch(userId: $0.authorId) }
        let users = (data.users ?? []).filter { !isBlockedForSearch(userId: $0.id) }
        if mineEntries.isEmpty && publicEntries.isEmpty && users.isEmpty {
            showNoneState(query: query)
            return
        }
        showingResults = true
        stateWrap.isHidden = true
        // 8-6 不变量：成功渲染时错误 wrap 必藏（它与 stateWrap 分属两个 arranged subview）。
        errorStateWrap.isHidden = true
        // 结果出现时最近搜索区隐藏（只属于初始态）。
        recentWrap.isHidden = true
        // 64 包回归修：成功路径必须把 resultsStack 改回可见——showState（加载/失败/
        // 无结果/初始）把它藏起后，旧代码只藏 stateWrap、从不恢复 resultsStack，
        // 结果行加进隐藏的栈，全程不可见。
        resultsStack.isHidden = false
        stateRingView.isHidden = true
        BearyIconMotion.stopSpin(on: stateRingView, key: "bearyStateSpin")
        clearResultRows()
        // G13：先建行、行数 >0 时再加分区头，避免全部行被跳过时空挂分区头。
        // 分区顺序与标题按网页 renderSrchResults：我的日记 · 私密 → 公开日记 → 用户。
        var mineRows: [UIView] = []
        for entry in mineEntries {
            if let row = makeEntryRow(entry: entry, query: query, isMineGroup: true) {
                mineRows.append(row)
            } else {
                // 5-20 nil 同步：makeEntryRow 在 id 缺失时返回 nil，且返回前未向
                // entryButtons / rowEntryIds / entryRowById 追加任何表项（追加只在
                // 成功末尾原子进行），故三表同步、无需插视觉占位行（插占位行会
                // 破坏 G13“全部行被跳过时不挂空分区头”）；animateResultRows 按 key
                // 查表，nil 行天然不在动画表中，不会错位到旧行。
            }
        }
        var publicRows: [UIView] = []
        for entry in publicEntries {
            if let row = makeEntryRow(entry: entry, query: query, isMineGroup: false) {
                publicRows.append(row)
            } else {
                // 5-20 nil 同步：同上，公开组 nil 行亦不进任何表、不插视觉占位行。
            }
        }
        var userRows: [UIView] = []
        for user in users {
            userRows.append(makeUserRow(user: user, query: query))
        }
        if !mineRows.isEmpty {
            resultsStack.addArrangedSubview(makeSectionHeader(title: "我的日记 · 私密"))
            for row in mineRows {
                resultsStack.addArrangedSubview(row)
            }
        }
        if !publicRows.isEmpty {
            resultsStack.addArrangedSubview(makeSectionHeader(title: "公开日记"))
            for row in publicRows {
                resultsStack.addArrangedSubview(row)
            }
        }
        if !userRows.isEmpty {
            resultsStack.addArrangedSubview(makeSectionHeader(title: "用户"))
            for row in userRows {
                resultsStack.addArrangedSubview(row)
            }
        }
        // M11：结果区首次出现/换批时行错峰滑入；同一批仅内容变化的行淡入。
        animateResultRows(query: query)
        // 88 包 M13：成功重渲后尾行隐藏。
        setSearchFooter(failed: false)
    }

    /// M11 入场口径：换关键词（新一批）→ 全部行错峰滑入；同关键词重渲
    /// （同一批仅内容变化）→ 仅新出现的行淡入，已有行不动。减动效直设终值。
    private var lastResultQuery: String?
    private var lastResultRowKeys: Set<String> = []

    private func animateResultRows(query: String) {
        let isNewBatch = lastResultQuery != query
        var nextKeys: Set<String> = []
        for entryId in rowEntryIds {
            nextKeys.insert("entry:" + entryId)
        }
        for user in rowUsers {
            if let key = userKey(for: user) {
                nextKeys.insert(key)
            }
        }
        let rowViews: [UIView] = entryButtons + userButtons
        if UIAccessibility.isReduceMotionEnabled {
            lastResultQuery = query
            lastResultRowKeys = nextKeys
            return
        }
        if isNewBatch {
            var delay: TimeInterval = 0
            for rowView in rowViews {
                rowView.alpha = 0
                rowView.transform = CGAffineTransform(translationX: 0, y: 8)
                UIView.animate(withDuration: 0.25, delay: delay, options: .curveEaseOut, animations: {
                    rowView.alpha = 1
                    rowView.transform = .identity
                })
                delay += 0.03
            }
        } else {
            // 同批（5-20 / 6-6 / 6-9）：按行身份 key 查视图，不按下标配对；
            // 仅新行错峰滑入（alpha + y+8、0.25s、0.03 步进封顶 0.24s，与新批同口径），
            // 已有行不动；查表不到（nil 跳过行）即跳过，不会把动画落到旧行。
            // 新旧区分走 lastResultRowKeys（Profile animatedRowIds 同款集合口径），
            // 故 6-9 不需“无法区分则不加”的兜底：区分在静态上已证实。
            var order = 0
            for entryId in rowEntryIds {
                let key = "entry:" + entryId
                if !lastResultRowKeys.contains(key), let rowView = entryRowById[entryId] {
                    rowView.alpha = 0
                    rowView.transform = CGAffineTransform(translationX: 0, y: 8)
                    let delay = min(Double(order) * 0.03, 0.24)
                    order += 1
                    UIView.animate(withDuration: 0.25, delay: delay, options: .curveEaseOut, animations: {
                        rowView.alpha = 1
                        rowView.transform = .identity
                    })
                }
            }
            for user in rowUsers {
                guard let key = userKey(for: user), !lastResultRowKeys.contains(key), let rowView = userRowByKey[key] else { continue }
                rowView.alpha = 0
                rowView.transform = CGAffineTransform(translationX: 0, y: 8)
                let delay = min(Double(order) * 0.03, 0.24)
                order += 1
                UIView.animate(withDuration: 0.25, delay: delay, options: .curveEaseOut, animations: {
                    rowView.alpha = 1
                    rowView.transform = .identity
                })
            }
        }
        lastResultQuery = query
        lastResultRowKeys = nextKeys
    }

    /// 分区头：网页 .srch-sec——12.5 bold gray、padding 12/6/4。
    private func makeSectionHeader(title: String) -> UIView {
        let wrap = UIView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 12.5))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = BearyColors.gray
        label.text = title
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -4),
        ])
        return wrap
    }

    /// 用户行：网页 .srch-user——padding 9/8、gap 11、头像 44 圆、名字 16.5 bold、
    /// handle 13 gray、右 chevron 16 gray；无图回退首字母大写、橙 14% 底橙字 17 bold。
    private func makeUserRow(user: SearchUser, query: String) -> UIButton {
        let row = UIButton(type: .custom)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.layer.cornerRadius = 14
        row.layer.masksToBounds = true

        let avatarView = UIImageView()
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.contentMode = .scaleAspectFill
        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 22
        avatarView.layer.masksToBounds = true

        let fallbackLabel = UILabel()
        fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
        fallbackLabel.font = BearyDynamicType.cappedFont(for: UIFont.boldSystemFont(ofSize: 17))
        fallbackLabel.adjustsFontForContentSizeCategory = true
        fallbackLabel.textColor = BearyColors.orange
        fallbackLabel.backgroundColor = BearyColors.orange.withAlphaComponent(0.14)
        fallbackLabel.textAlignment = .center
        fallbackLabel.layer.cornerRadius = 22
        fallbackLabel.layer.masksToBounds = true

        let nameLabel = BearyRoundedMarkLabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = BearyDynamicType.cardTitleFont()
        nameLabel.textColor = BearyColors.ink
        nameLabel.numberOfLines = 1
        nameLabel.clipsToBounds = true

        let handleLabel = BearyRoundedMarkLabel()
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        handleLabel.textColor = BearyColors.gray
        handleLabel.numberOfLines = 1
        handleLabel.clipsToBounds = true

        let chevron = UIImageView(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 16))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = BearyColors.gray
        chevron.contentMode = .scaleAspectFit

        let displayName = userDisplayName(user: user)
        nameLabel.attributedText = highlightedText(displayName, query: query, font: BearyDynamicType.cardTitleFont(), color: BearyColors.ink)
        if let handle = user.handle, !handle.isEmpty {
            let handleText = NSMutableAttributedString(string: "@")
            handleText.append(highlightedText(handle, query: query, font: BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13)), color: BearyColors.gray))
            handleLabel.attributedText = handleText
            handleLabel.isHidden = false
        } else {
            handleLabel.isHidden = true
        }
        // 图片失败重试：纯图标（icon_refresh 20pt，消息页头像重试同款；#224 误用 icon_restore 已回退），
        // 44×44 点击区居中压在头像上；仅失败态可见，加载中与成功态隐藏
        // （显隐由 BearySearchImageRetry 持有，见文件末尾）。
        let avatarRetryButton = UIButton(type: .custom)
        avatarRetryButton.translatesAutoresizingMaskIntoConstraints = false
        avatarRetryButton.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 20), for: .normal)
        avatarRetryButton.tintColor = BearyColors.ink
        avatarRetryButton.isHidden = true
        avatarRetryButton.accessibilityLabel = "重试"
        avatarRetryButton.accessibilityHint = "重新加载头像"

        if let avatarPath = user.avatarUrl, let url = BearyImageURLs.avatarURL(avatarPath) {
            let avatarRetry = BearySearchImageRetry(imageView: avatarView, retryButton: avatarRetryButton, imageURL: url)
            imageRetryHolders.append(avatarRetry)
            avatarRetry.load()
            avatarView.isHidden = false
            fallbackLabel.isHidden = true
        } else {
            avatarView.isHidden = true
            fallbackLabel.isHidden = false
            fallbackLabel.text = String(displayName.prefix(1)).uppercased()
        }

        row.addSubview(avatarView)
        row.addSubview(fallbackLabel)
        row.addSubview(avatarRetryButton)
        row.addSubview(nameLabel)
        row.addSubview(handleLabel)
        row.addSubview(chevron)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            avatarView.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            avatarView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            fallbackLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            fallbackLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            fallbackLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            fallbackLabel.widthAnchor.constraint(equalToConstant: 44),
            fallbackLabel.heightAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 71),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            handleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 71),
            handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            handleLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),
            // 8-15：用户行最小 44 高约束（现行行高 72，视觉不变，只保热区下限）。
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        row.addTarget(self, action: #selector(userRowTapped(_:)), for: .touchUpInside)
        row.addTarget(self, action: #selector(rowTouchDown(_:)), for: .touchDown)
        row.addTarget(self, action: #selector(rowTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        row.accessibilityLabel = displayName
        userButtons.append(row)
        rowUsers.append(user)
        if let key = userKey(for: user) {
            userRowByKey[key] = row
        }
        return row
    }

    /// 日记行：网页 .srch-entry——padding 14/16（Q1 行内边距统一）、底边 1 line；meta 行 gap 7（作者 13.5 bold、
    /// 日期 13 gray）；正文 16、行高 1.6、最多 3 行；首图 44×44 圆角 12 居右。
    /// 私密组 meta 为“日期 + 私密 pill”（2-3：只留 pill，“· 未公开”文字已删）；
    /// 公开组 meta 为“作者 + 日期 + · 我的（本人时）”。
    private func makeEntryRow(entry: Entry, query: String, isMineGroup: Bool) -> UIButton? {
        guard let entryId = entry.id else { return nil }
        let row = UIButton(type: .custom)
        row.translatesAutoresizingMaskIntoConstraints = false

        let metaStack = UIStackView()
        metaStack.translatesAutoresizingMaskIntoConstraints = false
        metaStack.axis = .horizontal
        metaStack.spacing = 7
        metaStack.alignment = .center

        let dateLabel = UILabel()
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = BearyColors.gray
        if let created = entry.createdAt {
            dateLabel.text = searchDateString(ms: created)
        }

        let contentText = collapsedWhitespace(entry.content ?? "")
        let contentLabel = BearyRoundedMarkLabel()
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.numberOfLines = 3
        contentLabel.lineBreakMode = .byCharWrapping
        contentLabel.clipsToBounds = true
        // 横向栈内正文先让位：固定 44 宽缩略图不被挤，正文换行承接剩余宽度。
        contentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentLabel.attributedText = highlightedText(contentText, query: query, font: BearyDynamicType.diaryBodyFont(), color: BearyColors.ink, lineHeightMultiple: 1.6, lineBreakMode: .byCharWrapping)

        let bodyRow = UIStackView()
        bodyRow.translatesAutoresizingMaskIntoConstraints = false
        bodyRow.axis = .horizontal
        bodyRow.spacing = 10
        bodyRow.alignment = .top
        bodyRow.addArrangedSubview(contentLabel)

        var thumbWrapView: UIView?
        // sweep32-6：私密组行也拼首图，与公开组同口径（44×44 圆角 12 居右、
        // 图失败重试图标同款）；无图时仍不拼图，行版式不变。
        // 首图包进 44×44 容器：图铺满容器，重试图标（与头像同款纯图标）
        // 44×44 居中压在图上；UIStackView 只排容器，图标不参与横排、不挤正文。
        // 行高随之调整：bodyRow 高度取正文与 44 缩略图之大（原私密行只有正文高）。
        if let images = entry.images, let firstKey = images.first, let url = BearyImageURLs.imageURL(key: firstKey, thumb: true) {
            let thumb = UIImageView()
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.contentMode = .scaleAspectFill
            thumb.clipsToBounds = true
            thumb.layer.cornerRadius = 12
            thumb.layer.masksToBounds = true
            let thumbRetryButton = UIButton(type: .custom)
            thumbRetryButton.translatesAutoresizingMaskIntoConstraints = false
            thumbRetryButton.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 20), for: .normal)
            thumbRetryButton.tintColor = BearyColors.ink
            thumbRetryButton.isHidden = true
            thumbRetryButton.accessibilityLabel = "重试"
            thumbRetryButton.accessibilityHint = "重新加载图片"
            let thumbWrap = UIView()
            thumbWrap.translatesAutoresizingMaskIntoConstraints = false
            thumbWrap.addSubview(thumb)
            thumbWrap.addSubview(thumbRetryButton)
            NSLayoutConstraint.activate([
                thumb.topAnchor.constraint(equalTo: thumbWrap.topAnchor),
                thumb.leadingAnchor.constraint(equalTo: thumbWrap.leadingAnchor),
                thumb.trailingAnchor.constraint(equalTo: thumbWrap.trailingAnchor),
                thumb.bottomAnchor.constraint(equalTo: thumbWrap.bottomAnchor),
                thumbRetryButton.centerXAnchor.constraint(equalTo: thumbWrap.centerXAnchor),
                thumbRetryButton.centerYAnchor.constraint(equalTo: thumbWrap.centerYAnchor),
                thumbRetryButton.widthAnchor.constraint(equalToConstant: 44),
                thumbRetryButton.heightAnchor.constraint(equalToConstant: 44),
            ])
            let thumbRetry = BearySearchImageRetry(imageView: thumb, retryButton: thumbRetryButton, imageURL: url)
            imageRetryHolders.append(thumbRetry)
            thumbRetry.load()
            thumbWrapView = thumbWrap
            bodyRow.addArrangedSubview(thumbWrap)
        }

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = BearyColors.line

        if isMineGroup {
            // 2-3：私密行只留 pill，不再拼“· 未公开”文字（双重状态文案已删）。
            metaStack.addArrangedSubview(dateLabel)
            metaStack.addArrangedSubview(makePrivatePill())
        } else {
            let authorLabel = BearyRoundedMarkLabel()
            authorLabel.translatesAutoresizingMaskIntoConstraints = false
            authorLabel.font = BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 13.5))
            authorLabel.textColor = BearyColors.ink
            authorLabel.numberOfLines = 1
            authorLabel.clipsToBounds = true
            authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            authorLabel.attributedText = highlightedText(entry.authorName ?? "", query: query, font: BearyDynamicType.scaledFont(for: UIFont.boldSystemFont(ofSize: 13.5)), color: BearyColors.ink)
            metaStack.addArrangedSubview(authorLabel)
            metaStack.addArrangedSubview(dateLabel)
            if let authorId = entry.authorId, let myUserId = SessionManager.shared.currentUser?.id, authorId == myUserId {
                let mineLabel = UILabel()
                mineLabel.translatesAutoresizingMaskIntoConstraints = false
                mineLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
                mineLabel.adjustsFontForContentSizeCategory = true
                mineLabel.textColor = BearyColors.gray
                mineLabel.text = "· 我的"
                metaStack.addArrangedSubview(mineLabel)
            }
        }

        // iCity 已举报态：搜索是刻意搜索例外，行保留（不删除），但置灰并标“已举报”。
        if BearyReportedStore.isReported(entryId: entryId) {
            let reportedLabel = UILabel()
            reportedLabel.translatesAutoresizingMaskIntoConstraints = false
            reportedLabel.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
            reportedLabel.adjustsFontForContentSizeCategory = true
            reportedLabel.textColor = BearyColors.gray
            reportedLabel.text = "已举报"
            metaStack.addArrangedSubview(reportedLabel)
            row.alpha = 0.6
        }

        let column = UIStackView(arrangedSubviews: [metaStack, bodyRow])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.spacing = 5
        row.addSubview(column)
        row.addSubview(separator)
        var constraints: [NSLayoutConstraint] = [
            column.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
            column.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -14),
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ]
        if let thumbWrap = thumbWrapView {
            constraints.append(thumbWrap.widthAnchor.constraint(equalToConstant: 44))
            constraints.append(thumbWrap.heightAnchor.constraint(equalToConstant: 44))
        }
        // 8-15：日记行最小 44 高约束（现行行高远超 44，视觉不变，只保热区下限）。
        constraints.append(row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44))
        NSLayoutConstraint.activate(constraints)

        entryRowById[entryId] = row
        row.addTarget(self, action: #selector(entryRowTapped(_:)), for: .touchUpInside)
        row.addTarget(self, action: #selector(rowTouchDown(_:)), for: .touchDown)
        row.addTarget(self, action: #selector(rowTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        row.accessibilityLabel = contentText
        entryButtons.append(row)
        rowEntryIds.append(entryId)
        return row
    }

    /// 私密 pill：网页 .tl-pill.priv——11.5 semibold 蓝字、蓝 13% 底、圆角 11、
    /// padding 2.5/9、锁图标 12、gap 4。圆角注（2-3 注释与代码对齐）：
    /// 实测高约 19（11.5 字 + 上下 2.5），圆角 11 已超半高 9.5，视觉近似 pill，
    /// 故代码保持 11、只改注释，不写 999。11.5 属装饰性小字，不走 Dynamic Type（8-3 豁免）。
    private func makePrivatePill() -> UIView {
        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = BearyColors.alpha(BearyColors.blue, 0.13)
        pill.layer.cornerRadius = 11
        pill.layer.masksToBounds = true
        let lock = UIImageView(image: BearyIconImages.image(named: "icon_lock", pointSize: 12))
        lock.translatesAutoresizingMaskIntoConstraints = false
        lock.tintColor = BearyColors.blue
        lock.contentMode = .scaleAspectFit
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = UIFont.systemFont(ofSize: 11.5, weight: .semibold)
        label.textColor = BearyColors.blue
        label.text = "私密"
        pill.addSubview(lock)
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            lock.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            lock.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            lock.widthAnchor.constraint(equalToConstant: 12),
            lock.heightAnchor.constraint(equalToConstant: 12),
            label.leadingAnchor.constraint(equalTo: lock.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2.5),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2.5),
        ])
        return pill
    }

    // MARK: - 行点按（只回调，容器接线）

    @objc private func userRowTapped(_ sender: UIButton) {
        for index in 0..<userButtons.count {
            if index < rowUsers.count && userButtons[index] == sender {
                // 补缺 P2-21：点按前比对拉黑表（渲染后新拉黑的竞态兜底）：命中则不行进主页，
                // 行即时摘掉并 toast，首渲染过滤与广播清行已覆盖常规路径。
                let user = rowUsers[index]
                if isBlockedForSearch(userId: user.id) {
                    if let userId = user.id { removeBlockedUserFromResults(userId: userId) }
                    BearyToast.show(in: view, message: "该用户已被拉黑")
                    return
                }
                onOpenUserHandler(user)
                return
            }
        }
    }

    @objc private func entryRowTapped(_ sender: UIButton) {
        for index in 0..<entryButtons.count {
            if index < rowEntryIds.count && entryButtons[index] == sender {
                // iCity §12：搜索结果点按记 search_click（只记 id，不记查询词；失败静默）。
                BearyAPI.shared.sendEvent(eventType: "search_click", targetId: rowEntryIds[index])
                onOpenEntryHandler(rowEntryIds[index])
                return
            }
        }
    }

    /// 按下态底色：网页 .srch-user:active 用 hov；日记行同口径跟随。
    @objc private func rowTouchDown(_ sender: UIButton) {
        sender.backgroundColor = BearyColors.hov
        // W6：搜索行已有底色按压反馈，只补 .light 轻震，不叠加缩放。
        BearyHaptics.press()
    }

    @objc private func rowTouchUp(_ sender: UIButton) {
        sender.backgroundColor = UIColor.clear
    }

    // MARK: - 文本工具

    /// 网页 hlKw 同口径：大小写不敏感、不重叠匹配，命中段橙底 mark。
    /// 网页 mark 样式：橙 24% 底、圆角 3、左右 padding 1；NSAttributedString 的
    /// .backgroundColor 画不出圆角，故命中段改记自定义属性，由
    /// BearyRoundedMarkLabel 在 drawText 里按段画圆角 3 底（见文件末尾）。
    private func highlightedText(_ text: String, query: String, font: UIFont, color: UIColor, lineHeightMultiple: CGFloat = 0, lineBreakMode: NSLineBreakMode = .byWordWrapping) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        if lineHeightMultiple > 0 {
            paragraph.lineHeightMultiple = lineHeightMultiple
        }
        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let result = NSMutableAttributedString(string: text, attributes: baseAttributes)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty || text.isEmpty {
            return result
        }
        let markAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            BearyRoundedMarkLabel.markColorKey: BearyColors.orange.withAlphaComponent(0.24),
        ]
        var searchStart = text.startIndex
        while searchStart < text.endIndex {
            guard let range = text.range(of: trimmedQuery, options: [.caseInsensitive], range: searchStart..<text.endIndex) else {
                break
            }
            let nsRange = NSRange(range, in: text)
            result.setAttributes(markAttributes, range: nsRange)
            searchStart = range.upperBound
        }
        return result
    }

    /// 网页正文展示口径：连续空白折成单个空格后再渲染。
    private func collapsedWhitespace(_ text: String) -> String {
        let parts = text.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter({ !$0.isEmpty })
        return parts.joined(separator: " ")
    }

    /// 网页 srchDateStr 口径：M 月 d 日（带空格，不带时间、不带年份）。
    private func searchDateString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M 月 d 日"
        return fmt.string(from: date)
    }

    /// 网页用户行名字回退口径：display_name || ('@' + handle) || 'beary 用户'。
    private func userDisplayName(user: SearchUser) -> String {
        if let display = user.displayName, !display.isEmpty {
            return display
        }
        if let handle = user.handle, !handle.isEmpty {
            return "@" + handle
        }
        return "beary 用户"
    }
}

// MARK: - 图片失败重试槽位（用户头像 / 日记首图共用）
//
// 形态（用户定）：纯图标，不带文字按钮——icon_refresh 20pt，消息页头像重试（#224 误用 icon_restore 已回退）
// 同款；按钮无背景无描边，图标色取动态 BearyColors.ink，故深浅切换无需重刷。
// 状态口径：加载中与成功态沿用现有行为（空白图 / 落图，重试图标隐藏）；
// 仅失败态亮重试图标，点它重新走 load()（先藏图标回到加载态），成功后图标消失。
// 代际守卫（消息页 avatarLoadGeneration 同款）：每次 load() 代际 +1，失败回调
// 凭捕获的代际与当前代际比对，不一致一律丢弃——行重建（本页每次渲染整体重建
// 结果区，旧行连同 holder 一起被 clearResultRows 丢弃）、换图、重试后，
// 旧回调均不得亮新行的重试图标。bearySetImage 自身另有目标 URL 比对与取消旧
// 任务，是第二重守卫；.cancelled 不算失败（bearySetImage 已过滤，不进 onFailure）。
// 无图槽位（头像为 null、日记无图）不建本槽位、不亮图标；私密组有图时亦建槽位（sweep32-6）。

private final class BearySearchImageRetry: NSObject {

    private let imageView: UIImageView
    private let retryButton: UIButton
    private let imageURL: URL
    private var generation: Int = 0

    init(imageView: UIImageView, retryButton: UIButton, imageURL: URL) {
        self.imageView = imageView
        self.retryButton = retryButton
        self.imageURL = imageURL
        super.init()
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retryButton.bearyAddPressFeedback()
    }

    func load() {
        generation += 1
        let capturedGeneration = generation
        retryButton.isHidden = true
        imageView.bearySetImage(url: imageURL, placeholder: nil) { [weak self] _ in
            guard let self = self else { return }
            guard capturedGeneration == self.generation else { return }
            self.retryButton.isHidden = false
        }
    }

    @objc private func retryTapped() {
        load()
    }
}

// MARK: - 圆角 mark label（网页 mark 圆角 3 的原生等价）
//
// NSAttributedString 的 .backgroundColor 是直角底，画不出圆角；本 label 在
// drawText 前用 CoreText 对 attributedText 做一次同字体/同段落样式的排版，
// 对带 markColorKey 属性的 run 逐段画圆角 3 填充（左右各扩 1px，
// 对应网页 mark padding 0 1px），再由 super 画文字。
// 约束与取舍：排版宽度取 drawText 的 rect，与 UILabel 自身布局同宽；
// 只画落入 rect 前 numberOfLines 行内的片段（截断行外的命中不画，
// 与 UILabel 截断后不可见一致）；单行截断尾部的省略号区若恰有命中，
// 底色可能盖到省略号上——属极少数长文本尾部命中，接受该偏差。

private final class BearyRoundedMarkLabel: UILabel {

    static let markColorKey = NSAttributedString.Key("BearyRoundedMarkColor")

    override func drawText(in rect: CGRect) {
        guard let attributed = attributedText else {
            super.drawText(in: rect)
            return
        }
        var hasMark = false
        attributed.enumerateAttribute(Self.markColorKey, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, stop in
            if value != nil {
                hasMark = true
                stop.pointee = true
            }
        }
        if !hasMark {
            super.drawText(in: rect)
            return
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine] else {
            super.drawText(in: rect)
            return
        }
        let maxLines = numberOfLines == 0 ? lines.count : min(numberOfLines, lines.count)
        var origins = [CGPoint](repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)
        for lineIndex in 0..<maxLines {
            let line = lines[lineIndex]
            let origin = origins[lineIndex]
            guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else {
                continue
            }
            for run in runs {
                let rawAttributes = CTRunGetAttributes(run) as NSDictionary
                guard let markColor = rawAttributes[Self.markColorKey.rawValue] as? UIColor else {
                    continue
                }
                let runRange = CTRunGetStringRange(run)
                let offset = CTLineGetOffsetForStringIndex(line, runRange.location, nil)
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let runWidth = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &ascent, &descent, nil)
                if runWidth <= 0 {
                    continue
                }
                // CoreText 坐标 y 向上、原点在 path 底部；UIKit 坐标 y 向下。
                let runTop = origin.y + ascent
                var runRect = CGRect(
                    x: rect.minX + origin.x + offset,
                    y: rect.minY + rect.height - runTop,
                    width: runWidth,
                    height: ascent + descent
                )
                if runRect.maxY < rect.minY || runRect.minY > rect.maxY {
                    continue
                }
                runRect = runRect.insetBy(dx: -1, dy: 0)
                markColor.setFill()
                UIBezierPath(roundedRect: runRect, cornerRadius: 3).fill()
            }
        }
        super.drawText(in: rect)
    }
}
