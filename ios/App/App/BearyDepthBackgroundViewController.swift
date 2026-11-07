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
    private let isPlusValue: Bool
    private let onPickValue: (Theme) -> Bool
    /// 滚动中：willDisplay 不再重开动效，停稳后才由滚动结束回调统一评估。
    private var isScrollingPreviews = false
    /// Plus 页的 EdgeDismiss 强持有（仅窄屏全屏路用，见 presentPlusPage）。
    private var plusPageEdgeDismiss: BearyEdgeDismissController?

    private let themesValue: [Theme] = [.none, .halloween, .spring, .china, .usa, .japan, .germany, .canada, .korea]

    init(currentTheme: Theme, isPlus: Bool, onPick: @escaping (Theme) -> Bool) {
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
        labelValue.text = "Plus 会员可使用全部景深背景"
        return labelValue
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BearyColors.bg
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = BearyColors.bg
        view.addSubview(topBarView)
        topBarView.addSubview(backButton)
        topBarView.addSubview(titleLabel)
        view.addSubview(tableView)
        if !isPlusValue {
            let footer = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 44))
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
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // 进页预热：只解当前已应用主题（个人页封面已在用，多半已缓存）；
        // 其余行由 cell 创建与 prefetch 按需触发，不再六张一次全幅解码
        //（第十轮 01：六张约 113 MiB，画质不降、只改加载时机＋内存预算）。
        if let currentCoverTheme = currentThemeValue.coverTheme {
            ProfileCoverView.prewarmBackdrops(for: [currentCoverTheme])
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshFullyVisiblePreviewAnimation()
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
        // 锁定档点按进 Plus 页（入口③），本页停留；门控 toast 仍留 handleFestivalThemePicked 作兜底。
        if theme != .none && !isPlusValue {
            presentPlusPage()
            return
        }
        // 门控／加载失败时个人页已弹 toast，本页停留；应用成功才关闭回个人页看效果。
        if onPickValue(theme) {
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
