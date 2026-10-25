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
//   + 搜索框（sticky：滚出后贴在安全区顶 6px 处）+ 框下恒高 24px 预留行
//   （已有结果时搜索中显示“正在搜索…”，平时占位透明）+ 状态区 / 结果区。
// 分区顺序（网页 renderSrchResults 同口径）：我的日记 · 未公开 → 公开日记 → 用户。
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
//     本页只取其中未公开（is_public != true）的篇目进“我的日记 · 未公开”组，
//     与网页 renderSrchResults 的 mine 过滤口径一致；未登录时服务端不给 mine，
//     私密分组自然不出现，不靠客户端登录态再拦一道。
//   - 免登录可搜公开内容：该接口本身不要求会话（无 session 时只缺 mine）。
//   - 回调线程：BearyAPI 回调不在主线程，碰 UI 前必须 DispatchQueue.main.async。

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
    private var searchFieldToBoxTrailing: NSLayoutConstraint?
    private var searchFieldToClearLeading: NSLayoutConstraint?
    private var boxTopConstraint: NSLayoutConstraint?
    private var searchSeq: Int = 0
    private var lastQuery: String = ""
    private var showingResults: Bool = false
    private var searchBoxFocused: Bool = false

    private var userButtons: [UIButton] = []
    private var rowUsers: [SearchUser] = []
    private var entryButtons: [UIButton] = []
    private var rowEntryIds: [String] = []
    // 图片失败重试槽位（用户头像 / 日记首图各一）：随行重建而丢弃，见文件末尾
    // BearySearchImageRetry；clearResultRows 时连同行一起清空。
    private var imageRetryHolders: [BearySearchImageRetry] = []

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let columnWrap = UIView()

    // 页顶返回行：网页 .tl-backrow——返回钮 28 + gap 10 + “搜索”标题 16/700，
    // 上下 padding 4/2；返回钮复用 chevron 右图旋转 180°（无新增资产）。
    private let backRowView = UIView()
    private let backButton = UIButton(type: .custom)
    private let backTitleLabel = UILabel()

    // 搜索框占位：框体本身是 view 级 sticky 视图，流内留 50 高占位，版式不跳动。
    private let boxPlaceholderView = UIView()

    // 框下预留行：网页 .srch-hint——恒高 24、12.5 灰、gap 6、左右 padding 4，
    // 平时透明占位（opacity 0），已有结果搜索中才显示“正在搜索…”。
    private let hintRowView = UIView()
    private let hintSpinner = UIActivityIndicatorView(style: .medium)
    private let hintLabel = UILabel()

    // 搜索框：网页 .srch-box——高 50、边框 1.5 line、圆角 999（半高 25）、左右 16、gap 9。
    private let searchBoxView = UIView()
    private let searchIconView = UIImageView()
    private let boxRingView = UIImageView()
    private let searchField = UITextField()
    private let clearButton = UIButton(type: .custom)

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
    private let retryButton = UIButton(type: .custom)

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        buildViews()
        buildConstraints()
        showInitialState()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateStickyBoxPosition()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateStickyBoxPosition()
    }

    /// sticky 框体顶距：占位在视野内时贴占位，滚出后贴安全区顶 6px（网页 top:6px）。
    private func updateStickyBoxPosition() {
        guard let boxTop = boxTopConstraint else { return }
        let safeTop = view.safeAreaLayoutGuide.layoutFrame.minY
        let placeholderTop = boxPlaceholderView.convert(CGPoint.zero, to: view).y
        let target = max(6, placeholderTop - safeTop)
        if abs(boxTop.constant - target) > 0.5 {
            boxTop.constant = target
        }
    }

    @objc private func backTapped() {
        onBack?()
    }

    /// 框下预留行显隐：只改透明度（.18s，网页 .srch-hint transition 同口径），高度恒 24。
    private func setSearchingHint(_ on: Bool) {
        if on {
            hintSpinner.startAnimating()
        } else {
            hintSpinner.stopAnimating()
        }
        UIView.animate(withDuration: 0.18) {
            self.hintRowView.alpha = on ? 1 : 0
        }
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
        // 网页 closeSearch 口径：清防抖计时、序号 +1 使在途请求回包失效。
        searchTimer?.invalidate()
        searchTimer = nil
        searchSeq += 1
    }

    deinit {
        searchTimer?.invalidate()
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
        backButton.setImage(BearyIconImages.image(named: "icon_chevron_right", pointSize: 16), for: .normal)
        backButton.tintColor = BearyColors.gray
        backButton.imageView?.transform = CGAffineTransform(rotationAngle: CGFloat.pi)
        backButton.accessibilityLabel = "返回"
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)
        backRowView.addSubview(backButton)

        backTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        backTitleLabel.font = UIFont.boldSystemFont(ofSize: 16)
        backTitleLabel.textColor = BearyColors.ink
        backTitleLabel.text = "搜索"
        backRowView.addSubview(backTitleLabel)

        // 搜索框占位（流内 50 高）与框下预留行（恒高 24）。
        boxPlaceholderView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(boxPlaceholderView)

        hintRowView.translatesAutoresizingMaskIntoConstraints = false
        hintRowView.alpha = 0
        contentStack.addArrangedSubview(hintRowView)

        hintSpinner.translatesAutoresizingMaskIntoConstraints = false
        hintSpinner.color = BearyColors.gray
        hintSpinner.hidesWhenStopped = true
        hintSpinner.transform = CGAffineTransform(scaleX: 0.75, y: 0.75)
        hintRowView.addSubview(hintSpinner)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = UIFont.systemFont(ofSize: 12.5)
        hintLabel.textColor = BearyColors.gray
        hintLabel.text = "正在搜索…"
        hintRowView.addSubview(hintLabel)

        // 搜索框：view 级视图（sticky 用，见 updateStickyBoxPosition），
        // 后于 scrollView 加入视图层级，滚动内容从它下方滑过时被盖住。
        searchBoxView.translatesAutoresizingMaskIntoConstraints = false
        searchBoxView.backgroundColor = BearyColors.bg
        searchBoxView.layer.borderWidth = 1.5
        searchBoxView.layer.cornerRadius = 25
        searchBoxView.layer.masksToBounds = true
        view.addSubview(searchBoxView)

        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchIconView.image = BearyIconImages.image(named: "icon_search", pointSize: 19)
        searchIconView.tintColor = BearyColors.gray
        searchIconView.contentMode = .scaleAspectFit
        searchBoxView.addSubview(searchIconView)

        boxRingView.translatesAutoresizingMaskIntoConstraints = false
        boxRingView.image = BearyIconImages.image(named: "icon_loading", pointSize: 19)
        boxRingView.tintColor = BearyColors.gray
        boxRingView.contentMode = .scaleAspectFit
        boxRingView.isHidden = true
        searchBoxView.addSubview(boxRingView)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = UIFont.systemFont(ofSize: 16)
        searchField.textColor = BearyColors.ink
        // 占位色走 BearyColors.gray（与登录/邀请页 attributedPlaceholder 同口径）。
        searchField.attributedPlaceholder = NSAttributedString(string: "搜索日记或用户", attributes: [
            .foregroundColor: BearyColors.gray,
            .font: UIFont.systemFont(ofSize: 16),
        ])
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchFieldChanged), for: .editingChanged)
        searchBoxView.addSubview(searchField)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.backgroundColor = BearyColors.faint
        clearButton.layer.cornerRadius = 13
        clearButton.layer.masksToBounds = true
        clearButton.setImage(BearyIconImages.image(named: "icon_close", pointSize: 13), for: .normal)
        clearButton.tintColor = BearyColors.gray
        clearButton.isHidden = true
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
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
        stateCircle.backgroundColor = BearyColors.orange.withAlphaComponent(0.18)
        stateCircle.layer.borderWidth = 1
        stateCircle.layer.cornerRadius = 27
        stateCircle.layer.masksToBounds = true
        stateStack.addArrangedSubview(stateCircle)

        stateIconView.translatesAutoresizingMaskIntoConstraints = false
        stateIconView.image = BearyIconImages.image(named: "icon_search", pointSize: 25)
        stateIconView.tintColor = BearyColors.orange
        stateIconView.contentMode = .scaleAspectFit
        stateCircle.addSubview(stateIconView)

        stateRingView.translatesAutoresizingMaskIntoConstraints = false
        stateRingView.image = BearyIconImages.image(named: "icon_loading", pointSize: 25)
        stateRingView.tintColor = BearyColors.orange
        stateRingView.contentMode = .scaleAspectFit
        stateRingView.isHidden = true
        stateCircle.addSubview(stateRingView)

        stateTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        stateTitleLabel.font = UIFont.boldSystemFont(ofSize: 15)
        stateTitleLabel.textColor = BearyColors.ink
        stateTitleLabel.textAlignment = .center
        stateTitleLabel.numberOfLines = 0
        stateStack.addArrangedSubview(stateTitleLabel)

        stateSubLabel.translatesAutoresizingMaskIntoConstraints = false
        stateSubLabel.font = UIFont.systemFont(ofSize: 12.5)
        stateSubLabel.textColor = BearyColors.gray
        stateSubLabel.textAlignment = .center
        stateSubLabel.numberOfLines = 0
        stateStack.addArrangedSubview(stateSubLabel)

        // 失败重试：网页 .addr-retry——padding 7/20、边框 1 line、圆角 999、13 ink、surface 底。
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重试", for: .normal)
        retryButton.setTitleColor(BearyColors.ink, for: .normal)
        retryButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        retryButton.backgroundColor = BearyColors.surface
        retryButton.layer.borderWidth = 1
        retryButton.layer.cornerRadius = 15
        retryButton.layer.masksToBounds = true
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 20, bottom: 7, right: 20)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        stateStack.addArrangedSubview(retryButton)

        // 结果区
        resultsStack.translatesAutoresizingMaskIntoConstraints = false
        resultsStack.axis = .vertical
        resultsStack.spacing = 0
        contentStack.addArrangedSubview(resultsStack)

        updateBorderColors()
    }

    private func buildConstraints() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // 内容列：容器已锁 600 列，页内不再二次收窄——列 = 满宽 ≤600 居中，
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
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            contentStack.bottomAnchor.constraint(equalTo: columnWrap.bottomAnchor),

            // 页顶返回行：按钮 28 + gap 10 + 标题，上下 padding 4/2。
            backButton.leadingAnchor.constraint(equalTo: backRowView.leadingAnchor),
            backButton.topAnchor.constraint(equalTo: backRowView.topAnchor, constant: 4),
            backButton.bottomAnchor.constraint(equalTo: backRowView.bottomAnchor, constant: -2),
            backButton.widthAnchor.constraint(equalToConstant: 28),
            backButton.heightAnchor.constraint(equalToConstant: 28),
            backTitleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 10),
            backTitleLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            backTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: backRowView.trailingAnchor),

            boxPlaceholderView.heightAnchor.constraint(equalToConstant: 50),

            // 框下预留行：恒高 24（不随显隐改高度，只改透明度）。
            hintRowView.heightAnchor.constraint(equalToConstant: 24),
            hintSpinner.leadingAnchor.constraint(equalTo: hintRowView.leadingAnchor, constant: 4),
            hintSpinner.centerYAnchor.constraint(equalTo: hintRowView.centerYAnchor),
            hintLabel.leadingAnchor.constraint(equalTo: hintSpinner.trailingAnchor, constant: 6),
            hintLabel.centerYAnchor.constraint(equalTo: hintRowView.centerYAnchor),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: hintRowView.trailingAnchor),

            // sticky 框体：与列内容同宽（16 边距 + ≤568 居中），顶距动态更新。
            searchBoxView.heightAnchor.constraint(equalToConstant: 50),
            searchBoxView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            searchBoxView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            searchBoxView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            searchBoxView.widthAnchor.constraint(lessThanOrEqualToConstant: 568),

            searchIconView.leadingAnchor.constraint(equalTo: searchBoxView.leadingAnchor, constant: 16),
            searchIconView.centerYAnchor.constraint(equalTo: searchBoxView.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 19),
            searchIconView.heightAnchor.constraint(equalToConstant: 19),

            boxRingView.leadingAnchor.constraint(equalTo: searchBoxView.leadingAnchor, constant: 16),
            boxRingView.centerYAnchor.constraint(equalTo: searchBoxView.centerYAnchor),
            boxRingView.widthAnchor.constraint(equalToConstant: 19),
            boxRingView.heightAnchor.constraint(equalToConstant: 19),

            searchField.leadingAnchor.constraint(equalTo: searchBoxView.leadingAnchor, constant: 44),
            searchField.topAnchor.constraint(equalTo: searchBoxView.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: searchBoxView.bottomAnchor),

            clearButton.trailingAnchor.constraint(equalTo: searchBoxView.trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: searchBoxView.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 26),
            clearButton.heightAnchor.constraint(equalToConstant: 26),

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
        // sticky 框体顶距：初始按返回行后位置估算，首次布局与滚动时校准。
        boxTopConstraint = searchBoxView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 38)
        boxTopConstraint?.isActive = true
        // 输入框右缘：清空钮显示时贴清空钮、无清空钮时贴框右 16（两条约束互斥切换）。
        searchFieldToBoxTrailing = searchField.trailingAnchor.constraint(equalTo: searchBoxView.trailingAnchor, constant: -16)
        searchFieldToClearLeading = searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8)
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
            // 网页 :focus-within 口径：边框取蓝 55% 混 line；原生以蓝 55% 透明度近似。
            searchBoxView.layer.borderColor = BearyColors.blue.withAlphaComponent(0.55).cgColor
        } else {
            searchBoxView.layer.borderColor = BearyColors.line.cgColor
        }
        // 状态圆描边：网页 inset 1px 橙 25% 圈。
        stateCircle.layer.borderColor = BearyColors.orange.withAlphaComponent(0.25).cgColor
        retryButton.layer.borderColor = BearyColors.line.cgColor
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
        if trimmed.isEmpty {
            setBoxBusy(false)
            setSearchingHint(false)
            showInitialState()
            return
        }
        // 网页口径：已有结果时保持结果区、框内圈转 + 框下预留行显示“正在搜索…”；
        // 无结果时结果区改加载态（含登录提示），预留行不亮。
        if showingResults {
            setBoxBusy(true)
            setSearchingHint(true)
        } else {
            setSearchingHint(false)
            showLoadingState()
        }
        BearyAPI.shared.search(q: trimmed) { [weak self] result in
            // BearyAPI 回调不在主线程，碰 UI 必须回主线程。
            DispatchQueue.main.async {
                guard let self = self else { return }
                if seq != self.searchSeq { return }
                self.setBoxBusy(false)
                self.setSearchingHint(false)
                switch result {
                case .success(let data):
                    self.renderResults(data: data, query: trimmed)
                case .failure:
                    self.showFailedState()
                }
            }
        }
    }

    /// 框内圈：加载时以转圈替换放大镜（网页 srchSetIconBusy 同款语义），
    /// 已有结果时另有框下预留行“正在搜索…”（见 setSearchingHint）。
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

    private func showState(title: String?, sub: String?, showRetry: Bool, loading: Bool) {
        showingResults = false
        resultsStack.isHidden = true
        clearResultRows()
        stateWrap.isHidden = false
        stateTitleLabel.text = title
        stateTitleLabel.isHidden = (title == nil)
        stateSubLabel.text = sub
        stateSubLabel.isHidden = (sub == nil)
        retryButton.isHidden = !showRetry
        stateIconView.isHidden = loading
        stateRingView.isHidden = !loading
        if loading {
            BearyIconMotion.startSpin(on: stateRingView, duration: 1, key: "bearyStateSpin")
        } else {
            BearyIconMotion.stopSpin(on: stateRingView, key: "bearyStateSpin")
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
        // 网页 fail 态：标题“搜索失败”+ 副文案“网络好像不太顺”+ 重试钮。
        showState(title: "搜索失败", sub: "网络好像不太顺", showRetry: true, loading: false)
    }

    private func showNoneState(query: String) {
        // 网页 none 态：标题“没有找到「q」”+ 副文案“换个关键词试试”。
        showState(title: "没有找到「" + query + "」", sub: "换个关键词试试", showRetry: false, loading: false)
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
        imageRetryHolders = []
    }

    private func renderResults(data: SearchResult, query: String) {
        // 我的组只取未公开篇（is_public != true，与网页 !e.is_public 同语义）。
        var mineEntries: [Entry] = []
        if let mine = data.mine {
            for entry in mine {
                if entry.isPublic != true {
                    mineEntries.append(entry)
                }
            }
        }
        let publicEntries = data.entries ?? []
        let users = data.users ?? []
        if mineEntries.isEmpty && publicEntries.isEmpty && users.isEmpty {
            showNoneState(query: query)
            return
        }
        showingResults = true
        stateWrap.isHidden = true
        stateRingView.isHidden = true
        BearyIconMotion.stopSpin(on: stateRingView, key: "bearyStateSpin")
        clearResultRows()
        // G13：先建行、行数 >0 时再加分区头，避免全部行被跳过时空挂分区头。
        // 分区顺序与标题按网页 renderSrchResults：我的日记 · 未公开 → 公开日记 → 用户。
        var mineRows: [UIView] = []
        for entry in mineEntries {
            if let row = makeEntryRow(entry: entry, query: query, isMineGroup: true) {
                mineRows.append(row)
            }
        }
        var publicRows: [UIView] = []
        for entry in publicEntries {
            if let row = makeEntryRow(entry: entry, query: query, isMineGroup: false) {
                publicRows.append(row)
            }
        }
        var userRows: [UIView] = []
        for user in users {
            userRows.append(makeUserRow(user: user, query: query))
        }
        if !mineRows.isEmpty {
            resultsStack.addArrangedSubview(makeSectionHeader(title: "我的日记 · 未公开"))
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
            if let userId = user.id {
                nextKeys.insert("user:\(userId)")
            } else if let handle = user.handle, !handle.isEmpty {
                nextKeys.insert("user:@\(handle)")
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
            // 同批：按行身份找新行淡入；entryButtons 与 rowEntryIds、userButtons 与
            // rowUsers 各自按下标一一对应（见 clearResultRows / make 行追加处）。
            for offset in 0..<entryButtons.count {
                guard offset < rowEntryIds.count else { continue }
                let key = "entry:" + rowEntryIds[offset]
                if !lastResultRowKeys.contains(key) {
                    let rowView = entryButtons[offset]
                    rowView.alpha = 0
                    UIView.animate(withDuration: 0.2, animations: {
                        rowView.alpha = 1
                    })
                }
            }
            for offset in 0..<userButtons.count {
                guard offset < rowUsers.count else { continue }
                let user = rowUsers[offset]
                var key: String?
                if let userId = user.id {
                    key = "user:\(userId)"
                } else if let handle = user.handle, !handle.isEmpty {
                    key = "user:@\(handle)"
                }
                if let keyValue = key, !lastResultRowKeys.contains(keyValue) {
                    let rowView = userButtons[offset]
                    rowView.alpha = 0
                    UIView.animate(withDuration: 0.2, animations: {
                        rowView.alpha = 1
                    })
                }
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
        label.font = UIFont.boldSystemFont(ofSize: 12.5)
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
        fallbackLabel.font = UIFont.boldSystemFont(ofSize: 17)
        fallbackLabel.textColor = BearyColors.orange
        fallbackLabel.backgroundColor = BearyColors.orange.withAlphaComponent(0.14)
        fallbackLabel.textAlignment = .center
        fallbackLabel.layer.cornerRadius = 22
        fallbackLabel.layer.masksToBounds = true

        let nameLabel = BearyRoundedMarkLabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
        nameLabel.textColor = BearyColors.ink
        nameLabel.numberOfLines = 1
        nameLabel.clipsToBounds = true

        let handleLabel = BearyRoundedMarkLabel()
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = UIFont.systemFont(ofSize: 13)
        handleLabel.textColor = BearyColors.gray
        handleLabel.numberOfLines = 1
        handleLabel.clipsToBounds = true

        let chevron = UIImageView(image: BearyIconImages.image(named: "icon_chevron_right", pointSize: 16))
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.tintColor = BearyColors.gray
        chevron.contentMode = .scaleAspectFit

        let displayName = userDisplayName(user: user)
        nameLabel.attributedText = highlightedText(displayName, query: query, font: UIFont.boldSystemFont(ofSize: 16.5), color: BearyColors.ink)
        if let handle = user.handle, !handle.isEmpty {
            let handleText = NSMutableAttributedString(string: "@")
            handleText.append(highlightedText(handle, query: query, font: UIFont.systemFont(ofSize: 13), color: BearyColors.gray))
            handleLabel.attributedText = handleText
            handleLabel.isHidden = false
        } else {
            handleLabel.isHidden = true
        }
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

        // 图片失败重试：纯图标（icon_refresh 20pt，消息页头像重试同款），
        // 44×44 点击区居中压在头像上；仅失败态可见，加载中与成功态隐藏
        // （显隐由 BearySearchImageRetry 持有，见文件末尾）。
        let avatarRetryButton = UIButton(type: .custom)
        avatarRetryButton.translatesAutoresizingMaskIntoConstraints = false
        avatarRetryButton.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 20), for: .normal)
        avatarRetryButton.tintColor = BearyColors.ink
        avatarRetryButton.isHidden = true
        avatarRetryButton.accessibilityLabel = "点击重试"
        avatarRetryButton.accessibilityHint = "重新加载头像"
        row.addSubview(avatarView)
        row.addSubview(fallbackLabel)
        row.addSubview(avatarRetryButton)
        row.addSubview(nameLabel)
        row.addSubview(handleLabel)
        row.addSubview(chevron)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            avatarView.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
            avatarView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            avatarView.widthAnchor.constraint(equalToConstant: 44),
            avatarView.heightAnchor.constraint(equalToConstant: 44),
            fallbackLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            fallbackLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
            fallbackLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            fallbackLabel.widthAnchor.constraint(equalToConstant: 44),
            fallbackLabel.heightAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
            avatarRetryButton.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),
            avatarRetryButton.widthAnchor.constraint(equalToConstant: 44),
            avatarRetryButton.heightAnchor.constraint(equalToConstant: 44),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            nameLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 63),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            handleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            handleLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 63),
            handleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
            handleLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -9),
            chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            chevron.widthAnchor.constraint(equalToConstant: 16),
            chevron.heightAnchor.constraint(equalToConstant: 16),
        ])
        row.addTarget(self, action: #selector(userRowTapped(_:)), for: .touchUpInside)
        row.addTarget(self, action: #selector(rowTouchDown(_:)), for: .touchDown)
        row.addTarget(self, action: #selector(rowTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        row.accessibilityLabel = displayName
        userButtons.append(row)
        rowUsers.append(user)
        return row
    }

    /// 日记行：网页 .srch-entry——padding 13/8、底边 1 line；meta 行 gap 7（作者 13.5 bold、
    /// 日期 13 gray）；正文 16、行高 1.6、最多 3 行；首图 44×44 圆角 10 居右。
    /// 私密组 meta 为“日期 + 私密 pill + · 未公开”；公开组 meta 为“作者 + 日期 + · 我的（本人时）”。
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
        dateLabel.font = UIFont.systemFont(ofSize: 13)
        dateLabel.textColor = BearyColors.gray
        if let created = entry.createdAt {
            dateLabel.text = searchDateString(ms: created)
        }

        let contentText = collapsedWhitespace(entry.content ?? "")
        let contentLabel = BearyRoundedMarkLabel()
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.numberOfLines = 3
        contentLabel.clipsToBounds = true
        // 横向栈内正文先让位：固定 44 宽缩略图不被挤，正文换行承接剩余宽度。
        contentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentLabel.attributedText = highlightedText(contentText, query: query, font: UIFont.systemFont(ofSize: 16), color: BearyColors.ink, lineHeightMultiple: 1.6)

        let bodyRow = UIStackView()
        bodyRow.translatesAutoresizingMaskIntoConstraints = false
        bodyRow.axis = .horizontal
        bodyRow.spacing = 10
        bodyRow.alignment = .top
        bodyRow.addArrangedSubview(contentLabel)

        var thumbWrapView: UIView?
        // 私密组行不拼缩略图（网页私密行 meta + 正文、无图）；公开组才拼首图。
        // 首图包进 44×44 容器：图铺满容器，重试图标（与头像同款纯图标）
        // 44×44 居中压在图上；UIStackView 只排容器，图标不参与横排、不挤正文。
        if !isMineGroup, let images = entry.images, let firstKey = images.first, let url = BearyImageURLs.imageURL(key: firstKey, thumb: true) {
            let thumb = UIImageView()
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.contentMode = .scaleAspectFill
            thumb.clipsToBounds = true
            thumb.layer.cornerRadius = 10
            thumb.layer.masksToBounds = true
            let thumbRetryButton = UIButton(type: .custom)
            thumbRetryButton.translatesAutoresizingMaskIntoConstraints = false
            thumbRetryButton.setImage(BearyIconImages.image(named: "icon_refresh", pointSize: 20), for: .normal)
            thumbRetryButton.tintColor = BearyColors.ink
            thumbRetryButton.isHidden = true
            thumbRetryButton.accessibilityLabel = "点击重试"
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
            metaStack.addArrangedSubview(dateLabel)
            metaStack.addArrangedSubview(makePrivatePill())
            let unpubLabel = UILabel()
            unpubLabel.translatesAutoresizingMaskIntoConstraints = false
            unpubLabel.font = UIFont.systemFont(ofSize: 13)
            unpubLabel.textColor = BearyColors.gray
            unpubLabel.text = "· 未公开"
            metaStack.addArrangedSubview(unpubLabel)
        } else {
            let authorLabel = BearyRoundedMarkLabel()
            authorLabel.translatesAutoresizingMaskIntoConstraints = false
            authorLabel.font = UIFont.boldSystemFont(ofSize: 13.5)
            authorLabel.textColor = BearyColors.ink
            authorLabel.numberOfLines = 1
            authorLabel.clipsToBounds = true
            authorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            authorLabel.attributedText = highlightedText(entry.authorName ?? "", query: query, font: UIFont.boldSystemFont(ofSize: 13.5), color: BearyColors.ink)
            metaStack.addArrangedSubview(authorLabel)
            metaStack.addArrangedSubview(dateLabel)
            if let authorId = entry.authorId, let myUserId = SessionManager.shared.currentUser?.id, authorId == myUserId {
                let mineLabel = UILabel()
                mineLabel.translatesAutoresizingMaskIntoConstraints = false
                mineLabel.font = UIFont.systemFont(ofSize: 13)
                mineLabel.textColor = BearyColors.gray
                mineLabel.text = "· 我的"
                metaStack.addArrangedSubview(mineLabel)
            }
        }

        let column = UIStackView(arrangedSubviews: [metaStack, bodyRow])
        column.translatesAutoresizingMaskIntoConstraints = false
        column.axis = .vertical
        column.spacing = 5
        row.addSubview(column)
        row.addSubview(separator)
        var constraints: [NSLayoutConstraint] = [
            column.topAnchor.constraint(equalTo: row.topAnchor, constant: 13),
            column.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 8),
            column.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -8),
            column.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -13),
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ]
        if let thumbWrap = thumbWrapView {
            constraints.append(thumbWrap.widthAnchor.constraint(equalToConstant: 44))
            constraints.append(thumbWrap.heightAnchor.constraint(equalToConstant: 44))
        }
        NSLayoutConstraint.activate(constraints)

        row.addTarget(self, action: #selector(entryRowTapped(_:)), for: .touchUpInside)
        row.addTarget(self, action: #selector(rowTouchDown(_:)), for: .touchDown)
        row.addTarget(self, action: #selector(rowTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        row.accessibilityLabel = contentText
        entryButtons.append(row)
        rowEntryIds.append(entryId)
        return row
    }

    /// 私密 pill：网页 .tl-pill.priv——11.5 semibold 蓝字、蓝 13% 底、圆角 999、
    /// padding 2.5/9、锁图标 12、gap 4。
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
                onOpenUserHandler(rowUsers[index])
                return
            }
        }
    }

    @objc private func entryRowTapped(_ sender: UIButton) {
        for index in 0..<entryButtons.count {
            if index < rowEntryIds.count && entryButtons[index] == sender {
                onOpenEntryHandler(rowEntryIds[index])
                return
            }
        }
    }

    /// 按下态底色：网页 .srch-user:active 用 hov；日记行同口径跟随。
    @objc private func rowTouchDown(_ sender: UIButton) {
        sender.backgroundColor = BearyColors.hov
    }

    @objc private func rowTouchUp(_ sender: UIButton) {
        sender.backgroundColor = UIColor.clear
    }

    // MARK: - 文本工具

    /// 网页 hlKw 同口径：大小写不敏感、不重叠匹配，命中段橙底 mark。
    /// 网页 mark 样式：橙 24% 底、圆角 3、左右 padding 1；NSAttributedString 的
    /// .backgroundColor 画不出圆角，故命中段改记自定义属性，由
    /// BearyRoundedMarkLabel 在 drawText 里按段画圆角 3 底（见文件末尾）。
    private func highlightedText(_ text: String, query: String, font: UIFont, color: UIColor, lineHeightMultiple: CGFloat = 0) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
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
// 形态（用户定）：纯图标，不带文字按钮——icon_refresh 20pt，消息页头像重试
// 同款；按钮无背景无描边，图标色取动态 BearyColors.ink，故深浅切换无需重刷。
// 状态口径：加载中与成功态沿用现有行为（空白图 / 落图，重试图标隐藏）；
// 仅失败态亮重试图标，点它重新走 load()（先藏图标回到加载态），成功后图标消失。
// 代际守卫（消息页 avatarLoadGeneration 同款）：每次 load() 代际 +1，失败回调
// 凭捕获的代际与当前代际比对，不一致一律丢弃——行重建（本页每次渲染整体重建
// 结果区，旧行连同 holder 一起被 clearResultRows 丢弃）、换图、重试后，
// 旧回调均不得亮新行的重试图标。bearySetImage 自身另有目标 URL 比对与取消旧
// 任务，是第二重守卫；.cancelled 不算失败（bearySetImage 已过滤，不进 onFailure）。
// 无图槽位（头像为 null、日记无图、私密组无缩略图）不建本槽位、不亮图标。

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
