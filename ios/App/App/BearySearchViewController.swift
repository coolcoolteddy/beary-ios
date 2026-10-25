import UIKit

// ===== beary 原生搜索页 =====
// 网页对照：~/workspace/teddy_site/beary.html 内 #searchPage（结构、文案、状态口径）
//   与 .srch-* CSS（尺寸见行内注释）；设计对照：~/workspace/previews/layout_rest.html
//   的 f-search 帧（分区顺序与标题）；后端对照：~/workspace/teddy_beary/worker.js
//   GET /beary/api/search（见下方“接口对照”）。
// 容器契约：本页只负责搜索与渲染，不含顶栏/底栏胶囊（容器 SceneDelegate 侧提供，
//   与其他内容页同口径）；点用户只回调 onOpenUser、点日记只回调 onOpenEntry，
//   跳转与个人主页打开一律由容器接线，本页不 present、不 push、不碰导航。
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

final class BearySearchViewController: UIViewController, UITextFieldDelegate {

    // MARK: - 对外 API（容器按此接线，勿改名）

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
    private var searchSeq: Int = 0
    private var lastQuery: String = ""
    private var showingResults: Bool = false
    private var searchBoxFocused: Bool = false

    private var userButtons: [UIButton] = []
    private var rowUsers: [SearchUser] = []
    private var entryButtons: [UIButton] = []
    private var rowEntryIds: [String] = []

    // MARK: - 视图

    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let columnWrap = UIView()

    // 搜索框：网页 .srch-box——高 50、边框 1.5 line、圆角 999（半高 25）、左右 16、gap 9。
    private let searchBoxView = UIView()
    private let searchIconView = UIImageView()
    private let boxSpinner = UIActivityIndicatorView(style: .medium)
    private let searchField = UITextField()
    private let clearButton = UIButton(type: .custom)

    // 结果区：每次渲染整体重建（与网页 body.innerHTML 重写同口径）。
    private let resultsStack = UIStackView()

    // 状态区：网页 .addr-state——容器 padding 28/20/20；圆 54、图标 25、标题 15、副文案 12.5。
    private let stateWrap = UIView()
    private let stateStack = UIStackView()
    private let stateCircle = UIView()
    private let stateIconView = UIImageView()
    private let stateSpinner = UIActivityIndicatorView(style: .medium)
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 网页 openSearch 会在 120ms 后聚焦输入框；原生页打开即聚焦，同口径。
        searchField.becomeFirstResponder()
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
        view.addSubview(scrollView)

        columnWrap.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(columnWrap)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        columnWrap.addSubview(contentStack)

        // 搜索框
        searchBoxView.translatesAutoresizingMaskIntoConstraints = false
        searchBoxView.backgroundColor = BearyColors.bg
        searchBoxView.layer.borderWidth = 1.5
        searchBoxView.layer.cornerRadius = 25
        searchBoxView.layer.masksToBounds = true
        contentStack.addArrangedSubview(searchBoxView)

        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        searchIconView.image = BearyIconImages.image(named: "icon_search", pointSize: 19)
        searchIconView.tintColor = BearyColors.gray
        searchIconView.contentMode = .scaleAspectFit
        searchBoxView.addSubview(searchIconView)

        boxSpinner.translatesAutoresizingMaskIntoConstraints = false
        boxSpinner.color = BearyColors.gray
        boxSpinner.hidesWhenStopped = true
        searchBoxView.addSubview(boxSpinner)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.font = UIFont.systemFont(ofSize: 16)
        searchField.textColor = BearyColors.ink
        searchField.placeholder = "搜索日记或用户"
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

        stateSpinner.translatesAutoresizingMaskIntoConstraints = false
        stateSpinner.color = BearyColors.orange
        stateSpinner.hidesWhenStopped = true
        stateCircle.addSubview(stateSpinner)

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

            // 内容列：网页 .pf-col——左右 16、最大宽 600 居中。
            columnWrap.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            columnWrap.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            columnWrap.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            columnWrap.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            columnWrap.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            contentStack.topAnchor.constraint(equalTo: columnWrap.topAnchor, constant: 4),
            contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: columnWrap.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: columnWrap.trailingAnchor, constant: -16),
            contentStack.centerXAnchor.constraint(equalTo: columnWrap.centerXAnchor),
            contentStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            contentStack.bottomAnchor.constraint(equalTo: columnWrap.bottomAnchor),

            searchBoxView.heightAnchor.constraint(equalToConstant: 50),

            searchIconView.leadingAnchor.constraint(equalTo: searchBoxView.leadingAnchor, constant: 16),
            searchIconView.centerYAnchor.constraint(equalTo: searchBoxView.centerYAnchor),
            searchIconView.widthAnchor.constraint(equalToConstant: 19),
            searchIconView.heightAnchor.constraint(equalToConstant: 19),

            boxSpinner.leadingAnchor.constraint(equalTo: searchBoxView.leadingAnchor, constant: 16),
            boxSpinner.centerYAnchor.constraint(equalTo: searchBoxView.centerYAnchor),

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

            stateSpinner.centerXAnchor.constraint(equalTo: stateCircle.centerXAnchor),
            stateSpinner.centerYAnchor.constraint(equalTo: stateCircle.centerYAnchor),
        ])
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
            showInitialState()
            return
        }
        // 网页口径：已有结果时保持结果区、只转框内圈；否则结果区改加载态。
        if showingResults {
            setBoxBusy(true)
        } else {
            showLoadingState()
        }
        BearyAPI.shared.search(q: trimmed) { [weak self] result in
            // BearyAPI 回调不在主线程，碰 UI 必须回主线程。
            DispatchQueue.main.async {
                guard let self = self else { return }
                if seq != self.searchSeq { return }
                self.setBoxBusy(false)
                switch result {
                case .success(let data):
                    self.renderResults(data: data, query: trimmed)
                case .failure:
                    self.showFailedState()
                }
            }
        }
    }

    /// 框内圈：加载时以转圈替换放大镜（网页 srchSetIconBusy 同款语义）；
    /// 不用静态放大镜加一行“正在搜索”文案——转圈本身就是加载态。
    private func setBoxBusy(_ busy: Bool) {
        searchIconView.isHidden = busy
        if busy {
            boxSpinner.startAnimating()
        } else {
            boxSpinner.stopAnimating()
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
        if loading {
            stateSpinner.startAnimating()
        } else {
            stateSpinner.stopAnimating()
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
        // 加载态：圆内转圈，不配静态放大镜、不配文字行。
        showState(title: nil, sub: nil, showRetry: false, loading: true)
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
        stateSpinner.stopAnimating()
        clearResultRows()
        // 分区顺序与标题按已批准设计稿 f-search 帧：用户 → 日记 → 我的日记 · 未公开。
        // （网页 renderSrchResults 的顺序是私密组在前、公开日记称“公开日记”；
        //  此处以设计稿为准，差异见交付说明。）
        if !users.isEmpty {
            resultsStack.addArrangedSubview(makeSectionHeader(title: "用户"))
            for user in users {
                resultsStack.addArrangedSubview(makeUserRow(user: user, query: query))
            }
        }
        if !publicEntries.isEmpty {
            resultsStack.addArrangedSubview(makeSectionHeader(title: "日记"))
            for entry in publicEntries {
                if let row = makeEntryRow(entry: entry, query: query, isMineGroup: false) {
                    resultsStack.addArrangedSubview(row)
                }
            }
        }
        if !mineEntries.isEmpty {
            resultsStack.addArrangedSubview(makeSectionHeader(title: "我的日记 · 未公开"))
            for entry in mineEntries {
                if let row = makeEntryRow(entry: entry, query: query, isMineGroup: true) {
                    resultsStack.addArrangedSubview(row)
                }
            }
        }
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

        let nameLabel = UILabel()
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = UIFont.boldSystemFont(ofSize: 16.5)
        nameLabel.textColor = BearyColors.ink
        nameLabel.numberOfLines = 1

        let handleLabel = UILabel()
        handleLabel.translatesAutoresizingMaskIntoConstraints = false
        handleLabel.font = UIFont.systemFont(ofSize: 13)
        handleLabel.textColor = BearyColors.gray
        handleLabel.numberOfLines = 1

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
            avatarView.bearySetImage(url: url, placeholder: nil)
            avatarView.isHidden = false
            fallbackLabel.isHidden = true
        } else {
            avatarView.isHidden = true
            fallbackLabel.isHidden = false
            fallbackLabel.text = String(displayName.prefix(1)).uppercased()
        }

        row.addSubview(avatarView)
        row.addSubview(fallbackLabel)
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
        let contentLabel = UILabel()
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        contentLabel.numberOfLines = 3
        // 横向栈内正文先让位：固定 44 宽缩略图不被挤，正文换行承接剩余宽度。
        contentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contentLabel.attributedText = highlightedText(contentText, query: query, font: UIFont.systemFont(ofSize: 16), color: BearyColors.ink, lineHeightMultiple: 1.6)

        let bodyRow = UIStackView()
        bodyRow.translatesAutoresizingMaskIntoConstraints = false
        bodyRow.axis = .horizontal
        bodyRow.spacing = 10
        bodyRow.alignment = .top
        bodyRow.addArrangedSubview(contentLabel)

        var thumbView: UIImageView?
        if let images = entry.images, let firstKey = images.first, let url = BearyImageURLs.imageURL(key: firstKey, thumb: true) {
            let thumb = UIImageView()
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.contentMode = .scaleAspectFill
            thumb.clipsToBounds = true
            thumb.layer.cornerRadius = 10
            thumb.layer.masksToBounds = true
            thumb.bearySetImage(url: url, placeholder: nil)
            thumbView = thumb
            bodyRow.addArrangedSubview(thumb)
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
            let authorLabel = UILabel()
            authorLabel.translatesAutoresizingMaskIntoConstraints = false
            authorLabel.font = UIFont.boldSystemFont(ofSize: 13.5)
            authorLabel.textColor = BearyColors.ink
            authorLabel.numberOfLines = 1
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
        if let thumb = thumbView {
            constraints.append(thumb.widthAnchor.constraint(equalToConstant: 44))
            constraints.append(thumb.heightAnchor.constraint(equalToConstant: 44))
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
        pill.backgroundColor = BearyColors.blue.withAlphaComponent(0.13)
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
    /// 网页 mark 样式：橙 24% 底、圆角 3；原生以橙 24% 透明度背景近似（NSAttributedString 无圆角背景）。
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
            .backgroundColor: BearyColors.orange.withAlphaComponent(0.24),
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

    /// 网页 srchDateStr 口径：M月d日（不带时间、不带年份）。
    private func searchDateString(ms: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日"
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
