import UIKit

// ===== 景深背景选择页（2026-11-03，Li 定流程）=====
// 入口：本人页点封面带 → 选择框「景深背景」→ 本页；他人页不进。
// 列表：默认／万圣节／春节／六地封面。节日行
// 与封面行都用真的视图做实时预览，动画只在行可见时开、滚出视野关（与个人
// 页 header 同款省电口径）。
// 拥有口径：Plus 拥有全部非默认款（含六张封面）；非 Plus 行显「Plus 专属」
// 锁定态、预览照常看，点按进 Plus 页（入口③，取代旧的只弹提示做法）、不应用；默认档人人可回；
// 当前档点按直接关闭。
// 深色压暗与 header 同值（黑遮罩 0.35，封面行不压）；减动效沿用包内 freeze。

final class BearyDepthBackgroundViewController: UIViewController {

    typealias Theme = BearyProfileViewController.FestivalTheme

    private let currentThemeValue: Theme
    /// 第十一轮 04：会员资格是可变快照，不再是 init 定值——Plus 可能在外层
    /// Plus 页→邀请页拿到，init 时的值会过期；回前台时重读（见 refreshPlusStatus）。
    private var isPlusValue: Bool
    /// 点按回调带上选择页最新已知 Plus 态，供个人页应用时再次验证权限
    ///（第十一轮 04：只认个人页 profile.plus 会把刚到账的 Plus 挡在门外）。
    private let onPickValue: (Theme, Bool) -> Bool
    /// 首次出现不拉 /me：值刚从个人页 profile.plus 传来；之后每次回前台再重读。
    private var hasAppearedOnce = false
    /// 审计四轮第 6 项：会员状态请求的代次——viewWillAppear 每次回前台都发
    /// 一次 /me，旧回包乱序到达会覆盖新状态；只认最新一次请求的回包。
    private var plusStatusRequestSequence = 0
    /// 滚动中：willDisplay 不再重开动效，停稳后才由滚动结束回调统一评估。
    private var isScrollingPreviews = false
    /// Plus 页的 EdgeDismiss 强持有（仅窄屏全屏路用，见 presentPlusPage）。
    private var plusPageEdgeDismiss: BearyEdgeDismissController?

    private let themesValue: [Theme] = [.none, .halloween, .spring, .china, .usa, .japan, .germany, .canada, .korea]

    init(currentTheme: Theme, isPlus: Bool, onPick: @escaping (Theme, Bool) -> Bool) {
        self.currentThemeValue = currentTheme
        self.isPlusValue = isPlus
        self.onPickValue = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    private let topBarView = UIView()

    private lazy var backButton: UIButton = {
        let buttonValue = UIButton(type: .custom)
        buttonValue.translatesAutoresizingMaskIntoConstraints = false
        buttonValue.setImage(BearyIconImages.image(named: "icon_back", pointSize: 24), for: .normal)
        buttonValue.tintColor = BearyColors.ink
        buttonValue.accessibilityLabel = "返回"
        buttonValue.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        buttonValue.bearyAddPressFeedback()
        return buttonValue
    }()

    private let titleLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.cappedFont(for: UIFont.systemFont(ofSize: 17, weight: .bold))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        labelValue.textAlignment = .center
        labelValue.text = "景深背景"
        return labelValue
    }()

    private lazy var tableView: UITableView = {
        let tableValue = UITableView(frame: .zero, style: .plain)
        tableValue.translatesAutoresizingMaskIntoConstraints = false
        tableValue.backgroundColor = BearyColors.bg
        tableValue.separatorStyle = .none
        tableValue.delaysContentTouches = false
        tableValue.rowHeight = UITableView.automaticDimension
        tableValue.estimatedRowHeight = 206
        tableValue.delegate = self
        tableValue.dataSource = self
        tableValue.prefetchDataSource = self
        tableValue.register(BearyDepthBackgroundCell.self, forCellReuseIdentifier: "BearyDepthBackgroundCell")
        return tableValue
    }()

    private lazy var plusFooterLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 13))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        labelValue.textAlignment = .center
        labelValue.numberOfLines = 0
        labelValue.text = "仅 Plus 会员可使用景深背景"
        return labelValue
    }()

    /// 内容列：宽 ≥821 时 600 居中，≤820 时屏宽减 32（许愿墙同款口径）；
    /// cap 只在宽屏激活，窄屏不收窄到 600。
    private var tableCapConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = BearyColors.bg
        view.addSubview(topBarView)
        topBarView.addSubview(backButton)
        topBarView.addSubview(titleLabel)
        view.addSubview(tableView)
        updatePlusFooter()
        // 内容列：centerX ＋ defaultHigh 的屏宽减 32 撑满（只靠 centerX＋两侧
        // 不等式列宽会跟着内容走，见 2026-11-02 居中列布局陷阱）；宽 ≥821 时
        // cap 600 生效居中，窄屏 cap 关掉、不收窄。
        let tableViewWidth = tableView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -32)
        tableViewWidth.priority = .defaultHigh
        let tableCap = tableView.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
        tableCapConstraint = tableCap
        NSLayoutConstraint.activate([
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.heightAnchor.constraint(equalToConstant: 44),
            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),
            titleLabel.centerXAnchor.constraint(equalTo: topBarView.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBarView.trailingAnchor, constant: -52),
            tableView.topAnchor.constraint(equalTo: topBarView.bottomAnchor),
            tableView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tableViewWidth,
            tableCap,
            tableView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            tableView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 进页预热：只解当前已应用主题（个人页封面已在用，多半已缓存）；
        // 其余行由 cell 创建与 prefetch 按需触发，不再六张一次全幅解码
        //（第十轮 01：六张约 113 MiB，画质不降、只改加载时机＋内存预算）。
        if let currentCoverTheme = currentThemeValue.coverTheme {
            ProfileCoverView.prewarmBackdrops(for: [currentCoverTheme])
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let wantCap = view.bounds.width >= 821
        if let cap = tableCapConstraint, cap.isActive != wantCap {
            cap.isActive = wantCap
        }
        // 审计四轮第 5 项：页宽定下来后按实宽重算页脚高（宽屏 600 封顶时
        // 标签可用宽与窄屏不同；viewDidLoad 时表宽未定，初算可能不准）。
        updatePlusFooterHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshPlusStatus()
        refreshFullyVisiblePreviewAnimation()
    }

    /// 第十一轮 04：回前台重读会员资格——Plus 可能在外层 Plus 页→邀请页
    /// 拿到（邀请绑定成功即发 Plus），init 时的快照会过期。首次出现不拉
    ///（值刚从个人页 profile.plus 传来）；之后每次回前台拉一次 /me。
    /// 失败静默保留旧值，不弹 toast、不把人判成非 Plus；/me 未下发 plus
    ///（nil）时同样保留旧值。只在值真的变了时才刷新行与底栏。
    /// 审计四轮第 6 项：发起时记下账号与请求序号，回调先校验——已有更新的
    /// 请求发出、或发起后已切号、或 /me 回包的账号与发起账号不符时，过期
    /// 回包直接丢弃，不写 isPlusValue。
    private func refreshPlusStatus() {
        guard hasAppearedOnce else { hasAppearedOnce = true; return }
        plusStatusRequestSequence += 1
        let sequence = plusStatusRequestSequence
        let accountId = BearyDraftStore.currentAccountId
        BearyAPI.shared.fetchMe { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard sequence == self.plusStatusRequestSequence else { return }
                guard BearyDraftStore.currentAccountId == accountId else { return }
                guard case .success(let user) = result, let plus = user?.plus else { return }
                if let userId = user?.id, let accountId, userId != accountId { return }
                guard plus != self.isPlusValue else { return }
                self.isPlusValue = plus
                self.updatePlusFooter()
                self.refreshVisibleLockStates()
            }
        }
    }

    /// Plus 态变化时同步底栏提示：非 Plus 显示“仅 Plus 会员可使用景深背景”，
    /// 已开通则去掉；与 viewDidLoad 初始态同口径。
    private func updatePlusFooter() {
        if isPlusValue {
            tableView.tableFooterView = nil
        } else if tableView.tableFooterView == nil {
            let footer = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: plusFooterHeight()))
            plusFooterLabel.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(plusFooterLabel)
            NSLayoutConstraint.activate([
                plusFooterLabel.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
                plusFooterLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
                plusFooterLabel.leadingAnchor.constraint(greaterThanOrEqualTo: footer.leadingAnchor, constant: 32),
                plusFooterLabel.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -32),
            ])
            tableView.tableFooterView = footer
        }
    }

    /// 审计四轮第 5 项：页脚高度按缩放后的文字实算，不再固定 44pt——
    /// tableFooterView 取 frame 高、不随内部 Auto Layout 增高，超大字号下
    /// 13pt 文字两行即超 44pt。常规字号仍为 44pt（文字高＋上下各 14pt）。
    private func plusFooterHeight() -> CGFloat {
        let tableWidth = tableView.bounds.width > 0 ? tableView.bounds.width : view.bounds.width
        let labelWidth = max(0, tableWidth - 64)
        let textHeight = plusFooterLabel.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height
        return max(44, ceil(textHeight) + 28)
    }

    /// 字号档／页宽变化后重算页脚高；高度没变不重设（viewDidLayoutSubviews
    /// 里重设 tableFooterView 会再触发一次布局，须防循环）。
    private func updatePlusFooterHeight() {
        guard let footer = tableView.tableFooterView, !isPlusValue else { return }
        let height = plusFooterHeight()
        guard abs(footer.frame.height - height) > 0.5 else { return }
        footer.frame.size.height = height
        tableView.tableFooterView = footer
    }

    /// 资格变化时只重配可见行：configure 同主题复用只改文字状态、不重建
    /// 预览视图、不重读图；滚动位置不动。
    private func refreshVisibleLockStates() {
        for cell in tableView.visibleCells {
            guard let cell = cell as? BearyDepthBackgroundCell,
                  let indexPath = tableView.indexPath(for: cell) else { continue }
            let theme = themesValue[indexPath.row]
            cell.configure(theme: theme, isCurrent: theme == currentThemeValue, isLocked: theme != .none && !isPlusValue)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        for cell in tableView.visibleCells {
            (cell as? BearyDepthBackgroundCell)?.setPreviewAnimationEnabled(false)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        for cell in tableView.visibleCells {
            (cell as? BearyDepthBackgroundCell)?.updateDim()
        }
        // 审计四轮第 5 项：字号档变化时重算页脚高（标签字体随系统字号自动
        // 缩放，但 tableFooterView 的 frame 高不会自己跟上去）。
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updatePlusFooterHeight()
        }
    }

    @objc private func backButtonTapped() {
        dismiss(animated: BearyMotion.animated(true), completion: nil)
    }
}

extension BearyDepthBackgroundViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return themesValue.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "BearyDepthBackgroundCell", for: indexPath) as! BearyDepthBackgroundCell
        let theme = themesValue[indexPath.row]
        let isCurrent = theme == currentThemeValue
        let isLocked = theme != .none && !isPlusValue
        cell.configure(theme: theme, isCurrent: isCurrent, isLocked: isLocked)
        return cell
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let cell = cell as? BearyDepthBackgroundCell else { return }
        // 只给完全可见的行开动效：半露出的行保持静态，滚动中一律先关、停稳再评估。
        let fullyVisible = tableView.bounds.contains(tableView.rectForRow(at: indexPath))
        cell.setPreviewAnimationEnabled(!isScrollingPreviews && fullyVisible)
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? BearyDepthBackgroundCell)?.setPreviewAnimationEnabled(false)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isScrollingPreviews = true
        for cell in tableView.visibleCells {
            (cell as? BearyDepthBackgroundCell)?.setPreviewAnimationEnabled(false)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { refreshFullyVisiblePreviewAnimation() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        refreshFullyVisiblePreviewAnimation()
    }

    /// 停稳后统一评估：只给完全可见的行开动效，半露出的行保持静态。
    private func refreshFullyVisiblePreviewAnimation() {
        isScrollingPreviews = false
        for cell in tableView.visibleCells {
            guard let cell = cell as? BearyDepthBackgroundCell,
                  let indexPath = tableView.indexPath(for: cell) else { continue }
            cell.setPreviewAnimationEnabled(tableView.bounds.contains(tableView.rectForRow(at: indexPath)))
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: BearyMotion.animated(true))
        let theme = themesValue[indexPath.row]
        // 当前档点按即关闭（已应用，不重走门控；Plus 过期后仍贴着旧主题时也不弹提示）。
        if theme == currentThemeValue {
            dismiss(animated: BearyMotion.animated(true), completion: nil)
            return
        }
        // 锁定档点按进 Plus 页（入口③），本页停留；门控 toast 仍留编辑资料页
        // 的 handleDepthThemePicked 作兜底。
        if theme != .none && !isPlusValue {
            presentPlusPage()
            return
        }
        // 门控／加载失败时个人页已弹 toast，本页停留；应用成功才关闭回个人页看效果。
        // 应用时带上本页最新已知 Plus 态再验一次权限（第十一轮 04）。
        if onPickValue(theme, isPlusValue) {
            dismiss(animated: BearyMotion.animated(true), completion: nil)
        }
    }

    /// Plus 页入口③：锁定行点按进 Plus 页。呈现口径与本页同款（窄屏全屏＋左边缘
    /// 右滑，宽屏默认呈现）；锁定行只在非 Plus 时出现，故此处恒为未开通态。
    private func presentPlusPage() {
        guard presentedViewController == nil else { return }
        let page = BearyPlusPageViewController(isPlus: isPlusValue)
        if traitCollection.horizontalSizeClass == .compact {
            page.modalPresentationStyle = .fullScreen
            let edgeDismiss = BearyEdgeDismissController()
            edgeDismiss.attach(to: page)
            page.transitioningDelegate = edgeDismiss
            plusPageEdgeDismiss = edgeDismiss
        }
        present(page, animated: BearyMotion.animated(true))
    }
}

extension BearyDepthBackgroundViewController: UITableViewDataSourcePrefetching {

    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        // 第十轮 01：即将出现的行先在后台解码（只暖封面行；节日行／默认行
        // 不走此缓存）。可见行由 cell 创建时各自触发加载，不必另暖。
        let themes = indexPaths.compactMap { indexPath -> ProfileCoverTheme? in
            guard indexPath.row < themesValue.count else { return nil }
            return themesValue[indexPath.row].coverTheme
        }
        if !themes.isEmpty { ProfileCoverView.prewarmBackdrops(for: themes) }
    }
}

/// 景深背景行：上为实时预览（节日款走真的 BearyFestivalWallpaperView，封面款
/// 走真的 ProfileCoverView，默认档为纯底色占位），下为主题名＋状态（已应用／
/// Plus 专属）。预览创建失败时（缺资源）退回纯底色占位，点按仍走个人页应用
/// 流程、失败由个人页 toast。
private final class BearyDepthBackgroundCell: UITableViewCell {

    private let previewContainer: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.clipsToBounds = true
        viewValue.layer.cornerRadius = 12
        viewValue.backgroundColor = BearyColors.surface2
        return viewValue
    }()

    private let dimView: UIView = {
        let viewValue = UIView()
        viewValue.translatesAutoresizingMaskIntoConstraints = false
        viewValue.backgroundColor = .black
        viewValue.alpha = 0
        viewValue.isUserInteractionEnabled = false
        viewValue.accessibilityElementsHidden = true
        return viewValue
    }()

    private let nameLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 17))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.ink
        return labelValue
    }()

    private let stateLabel: UILabel = {
        let labelValue = UILabel()
        labelValue.translatesAutoresizingMaskIntoConstraints = false
        labelValue.font = BearyDynamicType.scaledFont(for: UIFont.systemFont(ofSize: 14))
        labelValue.adjustsFontForContentSizeCategory = true
        labelValue.textColor = BearyColors.gray
        return labelValue
    }()

    private var wallpaperView: BearyFestivalWallpaperView?
    private var coverView: ProfileCoverView?
    private var currentTheme: BearyDepthBackgroundViewController.Theme?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        contentView.addSubview(previewContainer)
        previewContainer.addSubview(dimView)
        contentView.addSubview(nameLabel)
        contentView.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            previewContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            previewContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: BearySpace.lg),
            previewContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -BearySpace.lg),
            previewContainer.heightAnchor.constraint(equalToConstant: 150),
            dimView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            dimView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
            dimView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            nameLabel.topAnchor.constraint(equalTo: previewContainer.bottomAnchor, constant: 10),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: BearySpace.lg),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            stateLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            stateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            stateLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -BearySpace.lg),
        ])
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 只关动效、不拆预览视图：同主题复用时留住视图，省掉重建与重读图；
        // 换主题时 configure() 再拆旧建新。
        setPreviewAnimationEnabled(false)
    }

    func configure(theme: BearyDepthBackgroundViewController.Theme, isCurrent: Bool, isLocked: Bool) {
        let sameTheme = currentTheme == theme
        currentTheme = theme
        nameLabel.text = theme.title
        if isCurrent {
            stateLabel.text = "已应用"
            stateLabel.textColor = BearyColors.gray
        } else if isLocked {
            stateLabel.text = "Plus 专属"
            stateLabel.textColor = BearyColors.ink
        } else {
            stateLabel.text = nil
        }
        accessibilityLabel = isCurrent ? "\(theme.title)，已应用" : (isLocked ? "\(theme.title)，Plus 专属" : theme.title)
        if let coverTheme = theme.coverTheme {
            // 同主题复用：留住已建好的封面视图，只更新文字状态，不重建、不重读图。
            if sameTheme, coverView != nil {
                updateDim()
                return
            }
            wallpaperView?.removeFromSuperview()
            wallpaperView = nil
            coverView?.isPlaying = false
            coverView?.removeFromSuperview()
            coverView = nil
            let preview = ProfileCoverView(theme: coverTheme)
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.accessibilityElementsHidden = true
            preview.isPlaying = false
            previewContainer.insertSubview(preview, belowSubview: dimView)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            ])
            coverView = preview
            updateDim()
            return
        }
        // 非封面行：封面视图撤掉；节日视图同主题也留住。
        coverView?.isPlaying = false
        coverView?.removeFromSuperview()
        coverView = nil
        if sameTheme, wallpaperView != nil {
            updateDim()
            return
        }
        wallpaperView?.removeFromSuperview()
        wallpaperView = nil
        guard let wallpaperTheme = theme.wallpaperTheme else {
            updateDim()
            return
        }
        do {
            let preview = try BearyFestivalWallpaperView(theme: wallpaperTheme)
            preview.translatesAutoresizingMaskIntoConstraints = false
            preview.accessibilityElementsHidden = true
            preview.isAnimationEnabled = false
            previewContainer.insertSubview(preview, belowSubview: dimView)
            NSLayoutConstraint.activate([
                preview.topAnchor.constraint(equalTo: previewContainer.topAnchor),
                preview.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
                preview.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
                preview.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
            ])
            wallpaperView = preview
            updateDim()
        } catch {
            // 预览起不来不拦点按：应用时个人页会再试一次、失败弹 toast。
            wallpaperView = nil
        }
    }

    func setPreviewAnimationEnabled(_ enabled: Bool) {
        wallpaperView?.isAnimationEnabled = enabled
        coverView?.isPlaying = enabled
    }

    /// 深色压暗与 header 同值（黑遮罩 0.35，浅色 0）；封面行不压（插画本身
    /// 已铺满，压暗会闷住夜班车那张的灯光）。
    func updateDim() {
        if currentTheme?.wallpaperTheme != nil {
            dimView.alpha = traitCollection.userInterfaceStyle == .dark ? 0.35 : 0
        } else {
            dimView.alpha = 0
        }
    }
}
